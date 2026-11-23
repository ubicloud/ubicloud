# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ObjectGrowthReporter do
  let(:reporter) { described_class.new(interval: @interval || 600, top: 5) }

  after do
    expect(reporter.shutdown!).to be_nil
  end

  def emitted_reports
    reports = []
    allow(Clog).to receive(:emit).and_wrap_original do |m, msg, data|
      reports << data[:object_growth] if msg == "object growth"
      m.call(msg, data)
    end
    reports
  end

  describe ".create_if_enabled" do
    it "returns nil if reports are not enabled" do
      expect(described_class.create_if_enabled).to be_nil
    end

    it "returns a reporter if reports are enabled" do
      expect(Config).to receive(:object_growth_report_interval).and_return(600)
      expect(described_class.create_if_enabled).to be_a(described_class)
    end
  end

  it "#shutdown! works if the thread hasn't been started" do
    expect(reporter.shutdown!).to be_nil
  end

  it "#shutdown! works if the thread has been started" do
    thread = reporter.run_thread
    expect(reporter.shutdown!).to be_nil
    expect(thread.alive?).to be false
    expect(thread.value).to be true
  end

  it "#run_thread emits if run method fails" do
    expect(reporter).to receive(:run).and_raise(RuntimeError)
    expect(Clog).to receive(:emit).with("object growth reporter thread exiting due to unexpected error", Hash).and_call_original
    thread = reporter.run_thread
    expect(thread.join(1).value).to be false
  end

  it "#run reports once per interval until shutdown" do
    @interval = 0
    count = 0
    expect(reporter).to receive(:report).twice do
      count += 1
      reporter.shutdown_queue.push(true) if count == 2
    end
    reporter.run
  end

  it "#report emits a baseline, and then the classes with the largest increases" do
    reports = emitted_reports

    reporter.report
    baseline = reports.last
    expect(baseline).to include(baseline: true, report_number: 1)
    expect(baseline[:top_class_counts].length).to eq 5
    expect(baseline[:top_class_counts].first.keys).to eq %i[class count memsize]
    expect(baseline[:live_objects]).to be > 0
    expect(baseline[:gc]).to include(:heap_live_slots, :major_gc_count)
    expect(baseline[:gc][:heap_allocated_kb]).to eq baseline[:gc][:heap_allocated_pages] * 64
    expect(baseline[:smaps_rollup_kb]).to include(:rss, :anonymous, :private_dirty)
    expect(baseline).not_to include(:seconds_since_baseline, :gc_change_since_previous, :smaps_rollup_kb_change_since_baseline)

    # Retain many instances of a named class and of nested anonymous classes,
    # which should be grouped under their closest named superclass.
    anonymous_class = Class.new(Class.new(Prog::Base))
    retained = [
      Array.new(20_000) { Sshable::SshError.allocate },
      Array.new(10_000) { anonymous_class.allocate },
    ]

    reporter.report
    report = reports.last
    expect(report).to include(report_number: 2)
    expect(report).not_to include(:baseline, :top_class_counts)
    expect(report[:seconds_since_baseline]).to be >= 0
    expect(report[:live_objects_change_since_previous]).to be >= 30_000
    expect(report[:live_objects_change_since_baseline]).to eq report[:live_objects_change_since_previous]

    classes = report[:top_class_count_increases_since_baseline].to_h { [it[:class], it] }
    expect(classes["Sshable::SshError"][:count]).to be_within(5).of(20_000)
    expect(classes["Sshable::SshError"][:count_change]).to be_within(5).of(20_000)
    expect(classes["Sshable::SshError"][:memsize_change]).to be > 0
    expect(classes["#<anonymous Prog::Base>"][:count]).to be_within(5).of(10_000)
    expect(classes["#<anonymous Prog::Base>"][:count_change]).to be_within(5).of(10_000)
    expect(report[:top_class_count_increases_since_previous].map { it[:class] }).to include("Sshable::SshError")
    expect(report[:top_class_memsize_increases_since_baseline].map { it[:class] }).to include("Sshable::SshError")
    expect(report[:top_type_count_increases_since_baseline].map { it[:name] }).to include(:T_OBJECT)
    expect(report[:top_data_type_count_increases_since_baseline]).to be_a(Array)
    expect(report[:gc_change_since_previous].keys).to eq report[:gc].keys
    expect(report[:gc_change_since_previous][:major_gc_count]).to eq 1
    expect(report[:gc_change_since_baseline][:total_allocated_objects]).to be >= 30_000
    expect(report[:smaps_rollup_kb_change_since_previous].keys).to eq report[:smaps_rollup_kb].keys
    expect(report[:smaps_rollup_kb_change_since_baseline][:rss]).to eq(report[:smaps_rollup_kb][:rss] - baseline[:smaps_rollup_kb][:rss])

    # Once the objects are no longer retained, they no longer show up as increases.
    retained.clear
    reporter.report
    report = reports.last
    expect(report[:live_objects_change_since_previous]).to be < 0
    expect(report[:top_class_count_increases_since_previous].map { it[:class] }).not_to include("Sshable::SshError")
  end

  it "#report handles missing RSS and smaps_rollup information" do
    reports = emitted_reports
    reporter.report
    allow(File).to receive(:read).and_call_original
    expect(File).to receive(:read).with("/proc/self/status").and_raise(Errno::ENOENT)
    expect(File).to receive(:read).with("/proc/self/smaps_rollup").and_raise(Errno::ENOENT)
    reporter.report
    expect(reports.last).to include(rss_kb: nil, rss_kb_change_since_previous: nil, rss_kb_change_since_baseline: nil)
    expect(reports.last).not_to include(:smaps_rollup_kb, :smaps_rollup_kb_change_since_previous, :smaps_rollup_kb_change_since_baseline)
  end

  it "#report handles RSS and smaps_rollup information missing from files" do
    reports = emitted_reports
    allow(File).to receive(:read).and_call_original
    expect(File).to receive(:read).with("/proc/self/status").and_return("Name:\truby\n")
    expect(File).to receive(:read).with("/proc/self/smaps_rollup").and_return("7f00-7f01 ---p 00000000 00:00 0 [rollup]\nUnknown: 1 kB\n")
    reporter.report
    expect(reports.last).to include(rss_kb: nil)
    expect(reports.last).not_to include(:smaps_rollup_kb)
  end

  it "#report includes YJIT memory usage if YJIT is enabled" do
    reports = emitted_reports
    expect(RubyVM::YJIT).to receive(:enabled?).and_return(true).twice
    expect(RubyVM::YJIT).to receive(:runtime_stats).with(:yjit_alloc_size).and_return(1, 4)
    expect(RubyVM::YJIT).to receive(:runtime_stats).with(:code_region_size).and_return(2, 3)
    reporter.report
    expect(reports.last[:yjit]).to eq(yjit_alloc_size: 1, code_region_size: 2)
    reporter.report
    expect(reports.last[:yjit]).to eq(yjit_alloc_size: 4, code_region_size: 3)
    expect(reports.last[:yjit_change_since_previous]).to eq(yjit_alloc_size: 3, code_region_size: 1)
    expect(reports.last[:yjit_change_since_baseline]).to eq(yjit_alloc_size: 3, code_region_size: 1)
  end

  it "#report does not include YJIT memory usage if YJIT is not enabled" do
    reports = emitted_reports
    expect(RubyVM::YJIT).to receive(:enabled?).and_return(false).twice
    reporter.report
    reporter.report
    expect(reports.last).not_to include(:yjit, :yjit_change_since_previous, :yjit_change_since_baseline)
  end
end
