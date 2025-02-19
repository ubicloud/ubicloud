MRuby::Build.new do |conf|
  conf.toolchain :gcc
  conf.gem :mgem => 'mruby-json'
  conf.gem :mgem => 'mruby-curl'
  conf.gem :mgem => 'mruby-env'
  conf.gem :mgem => 'mruby-regexp-pcre'
  conf.gem :core => 'mruby-print'
  conf.gem :core => 'mruby-sprintf'
  conf.gem :core => 'mruby-exit'
end
