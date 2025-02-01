# frozen_string_literal: true

require "roda"
require "tilt"
require "tilt/erubi"

class EmailRenderer < Roda
  plugin :render, escape: true, template_opts: {chain_appends: !defined?(SimpleCov), freeze: true, skip_compiled_encoding_detection: true, scope_class: self, default_fixed_locals: "()", extract_fixed_locals: true}, assume_fixed_locals: true
  plugin :part
  plugin :mailer, terminal: true

  route do |r|
    r.mail "" do |receiver, subject, greeting: nil, body: nil, button_title: nil, button_link: nil, cc: nil, attachments: []|
      no_mail! if Array(receiver).compact.empty?
      from Config.mail_from
      to receiver
      subject subject
      cc cc

      attachments.each do |name, file|
        add_file filename: name, content: file
      end

      text_part "#{greeting}\n#{Array(body).join("\n")}\n#{button_link}"

      html_part(
        part("email/layout", subject:, greeting:, body:, button_title:, button_link:),
        "Content-Type" => "text/html; charset=UTF-8"
      )
    end
  end
end
