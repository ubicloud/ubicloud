#include <mruby.h>
#include <mruby/array.h>
#include <mruby/irep.h>
#include "ubi.c"

int
main(int argc, char** argv)
{
  mrb_state *mrb = mrb_open();
  int ret = 0;
  if (!mrb) { 
    fputs("Error during initialization\n", stderr);
    return 1;
  }

  mrb_value ARGV = mrb_ary_new_capa(mrb, argc);
  for (int i = 1; i < argc; i++) {
    char* utf8 = mrb_utf8_from_locale(argv[i], -1);
    mrb_ary_push(mrb, ARGV, mrb_str_new_cstr(mrb, utf8));
  }
  mrb_define_global_const(mrb, "ARGV", ARGV);

  mrb_load_irep(mrb, ubi);
  ret = mrb->exc ? 1 : 0;
  mrb_close(mrb);
  return ret;
}
