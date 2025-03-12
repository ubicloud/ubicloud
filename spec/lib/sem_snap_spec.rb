# frozen_string_literal: true

RSpec.describe SemSnap do
  let(:st) { Strand.create(prog: "Test", label: "start") }

  it "can decrement semaphores" do
    described_class.use(st.id) do |snap|
      expect {
        snap.incr(:test)
      }.to change { snap.set?(:test) }.from(false).to(true)

      expect(Semaphore.where(strand_id: st.id).empty?).to be false

      expect {
        snap.decr(:test)
      }.to change { snap.set?(:test) }.from(true).to(false)

      # Extra decrs are a no-op
      expect { snap.decr(:test) }.not_to raise_error

      # Deletions are deferred until block completion to reduce
      # time the records spend locked.
      expect(Semaphore.where(strand_id: st.id).empty?).to be false
    end

    expect(Semaphore.where(strand_id: st.id).empty?).to be true
  end

  it "operates immediately by default in non-block form" do
    snap = described_class.new(st.id)
    snap.incr(:test)
    delete_set = instance_double(Sequel::Model::DatasetMethods)
    expect(delete_set).to receive(:destroy)
    expect(Semaphore).to receive(:where).and_return(delete_set)
    snap.decr(:test)
  end

  it "reads semaphores at initialization" do
    described_class.new(st.id).incr(:test)
    expect(described_class.new(st.id).set?(:test)).to be true
  end

  it ".incr returns nil if strand no longer exists" do
    st.destroy
    snap = described_class.new(st.id)
    expect(snap.incr(:test)).to be_nil
  end
end
