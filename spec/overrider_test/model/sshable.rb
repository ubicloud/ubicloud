# frozen_string_literal: true

class Sshable
  module PrependClassMethods
    def override_class_method_check
      true
    end
  end

  module PrependMethods
    def override_instance_method_check
      true
    end
  end
end
