# frozen_string_literal: true

module SemaphoreMethods
  def self.configure(model, *semaphore_names)
    model.class_exec do
      one_to_many :semaphores, key: :strand_id

      semaphore_names << :destroying if semaphore_names.include?(:destroy) && !semaphore_names.include?(:destroying)
      @semaphore_names = semaphore_names.freeze

      semaphore_names.each do |sym|
        name = sym.name
        define_method :"incr_#{name}" do
          Semaphore.incr(id, sym)
        end

        define_method :"decr_#{name}" do
          Semaphore.where(strand_id: id, name:).delete
        end

        define_method :"#{name}_set?" do |cached: true|
          if cached
            semaphores.any? { it.name == name }
          else
            !semaphores_dataset.where(name:).empty?
          end
        end

        define_singleton_method :"incr_#{name}" do
          Semaphore.incr(it, sym)
        end
      end
    end
  end

  module ClassMethods
    attr_reader :semaphore_names
  end
end
