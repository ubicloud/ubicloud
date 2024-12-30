# frozen_string_literal: true

module SemaphoreMethods
  def self.included(base)
    base.class_eval do
      one_to_many :semaphores, key: :strand_id
    end
    base.extend(ClassMethods)
  end

  module ClassMethods
    def semaphore_names
      @semaphore_names || []
    end

    def semaphore(*names)
      (@semaphore_names ||= []).concat(names)
      names.each do |sym|
        name = sym.name
        define_method :"incr_#{name}" do
          Semaphore.incr(id, sym)
        end

        define_method :"#{name}_set?" do
          semaphores.any? { |s| s.name == name }
        end
      end
    end
  end
end
