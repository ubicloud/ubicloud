# frozen_string_literal: true

RSpec.describe SemSnap do
  let(:st) { Strand.create(prog: "Test", label: "start") }

  it "can decrement semaphores" do
    described_class.use(st.id) do |snap|
      expect {
        snap.incr(:test)
      }.to change { snap.set?(:test) }.from(false).to(true)

      # Use `#all` throughout for better error message printing, even
      # if not required for test constrints.
      expect(Semaphore.where(strand_id: st.id).all).not_to be_empty

      expect {
        snap.decr(:test)
      }.to change { snap.set?(:test) }.from(true).to(false)

      # Extra decrs are a no-op
      expect { snap.decr(:test) }.not_to raise_error

      # Deletions are deferred until block completion to reduce
      # time the records spend locked.
      expect(Semaphore.where(strand_id: st.id).all).not_to be_empty
    end

    expect(Semaphore.where(strand_id: st.id).all).to be_empty
  end

  it "operates immediately by default in non-block form" do
    snap = described_class.new(st.id)
    snap.incr(:test)

    expect { snap.decr(:test) }.to change {
      Semaphore.where(strand_id: st.id).count
    }.from(1).to(0)
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

  it ".sem_at returns nil if called for a non-extent semaphore" do
    expect(described_class.new(st.id).set_at(:test)).to be_nil
  end

  it ".sem_at returns time earliest semaphore was created" do
    snap = described_class.new(st.id)
    snap.incr(:test)
    t = Time.now - 65
    sem = Semaphore.create(name: "test", strand_id: st.id) do |sem|
      sem.id = UBID.generate_from_time(UBID::TYPE_SEMAPHORE, t).to_uuid
    end
    snap.send(:add_semaphore_instance_to_snapshot, sem)
    expect(described_class.new(st.id).set_at(:test)).to be_within(1).of(t)
  end
end
