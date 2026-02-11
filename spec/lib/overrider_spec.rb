# frozen_string_literal: true

# Cannot modify existing class during frozen tests.
# Skip if explicit override_dir is given, since the test overrides may not be set.
if Config.unfrozen_test? && !Config.override_dir
  RSpec.describe Overrider do
    it "considers PrependMethods before normal instance methods during method lookup" do
      expect(Sshable.allocate.override_instance_method_check).to be true
      expect(Sshable.ancestors[0..2]).to eq [NetSsh::WarnUnsafe::Sshable, Sshable::PrependMethods, Sshable]
    end

    it "considers PrependMethods before normal class methods during method lookup" do
      expect(Sshable.override_class_method_check).to be true
      expect(Sshable.singleton_class.ancestors[0..1]).to eq [Sshable::PrependClassMethods, Sshable.singleton_class]
    end
  end
end
