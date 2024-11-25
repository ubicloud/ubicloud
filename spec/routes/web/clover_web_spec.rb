# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover do
  it "handles CSRF token errors" do
    visit "/login"
    find("input[name=_csrf]", visible: false).set("")
    click_button "Sign in"

    expect(page.status_code).to eq(400)
    expect(page).to have_content("An invalid security token submitted with this request")
  end

  it "handles expected errors" do
    expect(Clog).to receive(:emit).with("route exception").and_call_original

    visit "/webhook/test-error"

    expect(page.title).to eq("Ubicloud - UnexceptedError")
  end

  it "raises unexpected errors in test environment" do
    expect(Clog).not_to receive(:emit)

    expect { visit "/webhook/test-error?message=treat+as+unexpected+error" }.to raise_error(RuntimeError)
  end

  it "does not have broken links" do
    create_account
    login

    visited = {"" => true}
    failures = []
    queue = Queue.new
    queue.push("/")

    pop = lambda do
      queue.pop(true)
    rescue ThreadError
    end

    while (path = pop.call)
      next if visited[path]
      visited[path] = true
      visit path

      if page.status_code == 404
        failures << path
      end

      if page.response_headers["content-type"].include?("text/html")
        links = page.all("a").map do |a|
          a["href"].sub(/#.*\z/, "")
        end

        links.reject! do |path|
          path.empty? || path.start_with?(%r{https://|mailto:})
        end

        links.each do |path|
          queue.push path
        end
      end
    end

    expect(failures).to be_empty
  end
end
