#include <linux/module.h>
#include <linux/export-internal.h>
#include <linux/compiler.h>

MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};



static const struct modversion_info ____versions[]
__used __section("__versions") = {
	{ 0xd272d446, "__fentry__" },
	{ 0xbd03ed67, "__ref_stack_chk_guard" },
	{ 0x55e5dc35, "acpi_get_handle" },
	{ 0xd272d446, "__stack_chk_fail" },
	{ 0x769c429b, "acpi_execute_simple_method" },
	{ 0x67628f51, "msleep" },
	{ 0xcc1d5ac5, "param_ops_int" },
	{ 0xe8213e80, "_printk" },
	{ 0xd272d446, "__x86_return_thunk" },
	{ 0xe9196a28, "module_layout" },
};

static const u32 ____version_ext_crcs[]
__used __section("__version_ext_crcs") = {
	0xd272d446,
	0xbd03ed67,
	0x55e5dc35,
	0xd272d446,
	0x769c429b,
	0x67628f51,
	0xcc1d5ac5,
	0xe8213e80,
	0xd272d446,
	0xe9196a28,
};
static const char ____version_ext_names[]
__used __section("__version_ext_names") =
	"__fentry__\0"
	"__ref_stack_chk_guard\0"
	"acpi_get_handle\0"
	"__stack_chk_fail\0"
	"acpi_execute_simple_method\0"
	"msleep\0"
	"param_ops_int\0"
	"_printk\0"
	"__x86_return_thunk\0"
	"module_layout\0"
;

MODULE_INFO(depends, "");


MODULE_INFO(srcversion, "561CAF45216F24483E9862D");
