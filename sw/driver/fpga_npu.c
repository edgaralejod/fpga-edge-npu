// SPDX-License-Identifier: GPL-2.0
/*
 * fpga-npu: Linux driver for the fpga-edge-npu PCIe card (10ee:ed10).
 *
 * The kernel part is deliberately small, the way accelerator stacks usually
 * split the work: it owns the PCI device, one DMA arena and the interrupt,
 * and hands them to user space. The command queue itself (rings, doorbells,
 * completions; docs/command-queue.md) is driven by the user-space runtime in
 * sw/npu/, which maps:
 *
 *   mmap offset 0                     the DMA arena (coherent, ARENA_SIZE)
 *   mmap offset FPGA_NPU_BAR0_OFFSET  BAR0, the card's registers (uncached)
 *
 * ioctl FPGA_NPU_IOC_INFO returns the arena's bus address (what the card
 * uses) and the sizes. read() returns the 32-bit count of interrupts seen,
 * blocking until it differs from the value written by the last read (or
 * returning at once with O_NONBLOCK); poll() reports a new interrupt.
 *
 * The bridge's window reaches host bus addresses below 2 GiB, so the DMA mask
 * is 31 bits; with the i.MX95's IOMMU on, the arena is mapped there for the
 * card whatever its physical pages are.
 */

#include <linux/fs.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mm.h>
#include <linux/pci.h>
#include <linux/poll.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#include "fpga_npu.h"

#define DRV_NAME   "fpga-npu"
#define ARENA_SIZE (32u << 20)

struct npu_dev {
	struct pci_dev *pdev;
	void __iomem *bar0;
	resource_size_t bar0_start, bar0_len;
	void *arena;
	dma_addr_t arena_bus;
	int irq;
	atomic_t irq_count;
	wait_queue_head_t wq;
	struct miscdevice misc;
};

static struct npu_dev *the_npu;   /* one card per host in this project */

static irqreturn_t npu_irq(int irq, void *data)
{
	struct npu_dev *npu = data;

	atomic_inc(&npu->irq_count);
	wake_up_interruptible(&npu->wq);
	return IRQ_HANDLED;
}

struct npu_file {
	struct npu_dev *npu;
	u32 seen;   /* interrupt count returned by the last read */
};

static int npu_open(struct inode *inode, struct file *f)
{
	struct npu_file *nf = kzalloc(sizeof(*nf), GFP_KERNEL);

	if (!nf)
		return -ENOMEM;
	nf->npu = the_npu;
	nf->seen = atomic_read(&the_npu->irq_count);
	f->private_data = nf;
	return 0;
}

static int npu_release(struct inode *inode, struct file *f)
{
	kfree(f->private_data);
	return 0;
}

static ssize_t npu_read(struct file *f, char __user *buf, size_t len, loff_t *off)
{
	struct npu_file *nf = f->private_data;
	struct npu_dev *npu = nf->npu;
	u32 count;
	int ret;

	if (len < sizeof(u32))
		return -EINVAL;
	if (!(f->f_flags & O_NONBLOCK)) {
		ret = wait_event_interruptible(npu->wq, (u32)atomic_read(&npu->irq_count) != nf->seen);
		if (ret)
			return ret;
	}
	count = atomic_read(&npu->irq_count);
	nf->seen = count;
	if (copy_to_user(buf, &count, sizeof(count)))
		return -EFAULT;
	return sizeof(count);
}

static __poll_t npu_poll(struct file *f, poll_table *wait)
{
	struct npu_file *nf = f->private_data;

	poll_wait(f, &nf->npu->wq, wait);
	return (u32)atomic_read(&nf->npu->irq_count) != nf->seen ? EPOLLIN | EPOLLRDNORM : 0;
}

static int npu_mmap(struct file *f, struct vm_area_struct *vma)
{
	struct npu_dev *npu = ((struct npu_file *)f->private_data)->npu;
	unsigned long len = vma->vm_end - vma->vm_start;
	unsigned long off = vma->vm_pgoff << PAGE_SHIFT;

	if (off == 0) {
		if (len > ARENA_SIZE)
			return -EINVAL;
		return dma_mmap_coherent(&npu->pdev->dev, vma, npu->arena, npu->arena_bus, len);
	}
	if (off == FPGA_NPU_BAR0_OFFSET) {
		if (len > npu->bar0_len)
			return -EINVAL;
		vma->vm_pgoff = 0;
		vma->vm_page_prot = pgprot_device(vma->vm_page_prot);
		return vm_iomap_memory(vma, npu->bar0_start, len);
	}
	return -EINVAL;
}

static long npu_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct npu_dev *npu = ((struct npu_file *)f->private_data)->npu;
	struct fpga_npu_info info = {
		.arena_bus = npu->arena_bus,
		.arena_size = ARENA_SIZE,
		.bar0_size = npu->bar0_len,
		.irq_count = atomic_read(&npu->irq_count),
	};

	if (cmd != FPGA_NPU_IOC_INFO)
		return -ENOTTY;
	return copy_to_user((void __user *)arg, &info, sizeof(info)) ? -EFAULT : 0;
}

static const struct file_operations npu_fops = {
	.owner = THIS_MODULE,
	.open = npu_open,
	.release = npu_release,
	.read = npu_read,
	.poll = npu_poll,
	.mmap = npu_mmap,
	.unlocked_ioctl = npu_ioctl,
};

static int npu_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct npu_dev *npu;
	int ret;

	if (the_npu)
		return -EBUSY;
	npu = devm_kzalloc(&pdev->dev, sizeof(*npu), GFP_KERNEL);
	if (!npu)
		return -ENOMEM;
	npu->pdev = pdev;
	atomic_set(&npu->irq_count, 0);
	init_waitqueue_head(&npu->wq);

	ret = pcim_enable_device(pdev);
	if (ret)
		return ret;
	pci_set_master(pdev);
	ret = pcim_request_all_regions(pdev, DRV_NAME);
	if (ret)
		return ret;
	npu->bar0_start = pci_resource_start(pdev, 0);
	npu->bar0_len = pci_resource_len(pdev, 0);
	npu->bar0 = pcim_iomap(pdev, 0, 0);
	if (!npu->bar0)
		return -ENOMEM;

	/* The card reaches host bus addresses below 2 GiB (fixed bridge window). */
	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(31));
	if (ret)
		return ret;
	npu->arena = dmam_alloc_coherent(&pdev->dev, ARENA_SIZE, &npu->arena_bus, GFP_KERNEL);
	if (!npu->arena)
		return -ENOMEM;

	ret = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI);
	if (ret < 0)
		return ret;
	npu->irq = pci_irq_vector(pdev, 0);
	ret = devm_request_irq(&pdev->dev, npu->irq, npu_irq, 0, DRV_NAME, npu);
	if (ret)
		goto err_vec;

	npu->misc.minor = MISC_DYNAMIC_MINOR;
	npu->misc.name = DRV_NAME;
	npu->misc.fops = &npu_fops;
	npu->misc.mode = 0660;
	the_npu = npu;
	ret = misc_register(&npu->misc);
	if (ret)
		goto err_irq;
	pci_set_drvdata(pdev, npu);

	dev_info(&pdev->dev, "BAR0 %pa (%llu bytes), arena %u MiB at bus %pad, MSI irq %d\n",
		 &npu->bar0_start, (unsigned long long)npu->bar0_len, ARENA_SIZE >> 20,
		 &npu->arena_bus, npu->irq);
	return 0;

err_irq:
	the_npu = NULL;
	devm_free_irq(&pdev->dev, npu->irq, npu);
err_vec:
	pci_free_irq_vectors(pdev);
	return ret;
}

static void npu_remove(struct pci_dev *pdev)
{
	struct npu_dev *npu = pci_get_drvdata(pdev);

	/* Stop the command queue before its rings go away. */
	writel(0, npu->bar0 + FPGA_NPU_REG_CQ_CTRL);
	misc_deregister(&npu->misc);
	devm_free_irq(&pdev->dev, npu->irq, npu);
	pci_free_irq_vectors(pdev);
	the_npu = NULL;
}

static const struct pci_device_id npu_ids[] = {
	{ PCI_DEVICE(0x10ee, 0xed10) },
	{ }
};
MODULE_DEVICE_TABLE(pci, npu_ids);

static struct pci_driver npu_driver = {
	.name = DRV_NAME,
	.id_table = npu_ids,
	.probe = npu_probe,
	.remove = npu_remove,
};
module_pci_driver(npu_driver);

MODULE_DESCRIPTION("fpga-edge-npu PCIe card: DMA arena, BAR0 and MSI for the user-space runtime");
MODULE_AUTHOR("Edgar Duarte");
MODULE_LICENSE("GPL");
