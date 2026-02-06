# frozen_string_literal: true

module SemaphoreMethods
  def self.configure(model, *semaphore_names)
    model.class_exec do
      one_to_many :semaphores, key: :strand_id

      semaphore_names << :destroying if semaphore_names.include?(:destroy) && !semaphore_names.include?(:destroying)
      @semaphore_names = semaphore_names.freeze

      semaphore_names.each do |sym|
        name = sym.name
        define_method :"incr_#{name}" do |request_ids = nil|
          Semaphore.incr(id, sym, request_ids)
        end

        define_method :"#{name}_set?" do
          semaphores.any? { it.name == name }
        end
      end
    end
  end

  module ClassMethods
    attr_reader :semaphore_names
  end
end
