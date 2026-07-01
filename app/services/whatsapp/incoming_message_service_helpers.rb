module Whatsapp::IncomingMessageServiceHelpers
  def download_attachment_file(attachment_payload)
    Down.download(inbox.channel.media_url(attachment_payload[:id]), headers: inbox.channel.api_headers)
  end

  def conversation_params
    {
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    }
  end

  def processed_params
    @processed_params ||= params
  end

  def account
    @account ||= inbox.account
  end

  def message_type
    messages_data.first[:type]
  end

  def message_content(message)
    if nfm_reply?(message)
      nfm = message.dig(:interactive, :nfm_reply)
      return format_nfm_reply_content(parse_nfm_reply_json(message), nfm[:body])
    end

    # TODO: map interactive messages back to button messages in chatwoot
    message.dig(:text, :body) ||
      message.dig(:button, :text) ||
      message.dig(:interactive, :button_reply, :title) ||
      message.dig(:interactive, :list_reply, :title) ||
      message.dig(:name, :formatted_name)
  end

  def nfm_reply?(message)
    message.dig(:interactive, :type) == 'nfm_reply'
  end

  def parse_nfm_reply_json(message)
    json = message.dig(:interactive, :nfm_reply, :response_json)
    return {} if json.blank?

    JSON.parse(json).stringify_keys
  rescue JSON::ParserError => e
    Rails.logger.warn("[Whatsapp] Failed to parse nfm_reply response_json: #{e.message}")
    {}
  end

  NFM_REPLY_FIELD_LABELS = {
    'full_name' => 'Name',
    'email' => 'Email',
    'country' => 'Country',
    'interested_in' => 'Interested in',
    'occupation' => 'Occupation'
  }.freeze

  def format_nfm_reply_content(form_data, fallback_body = nil)
    return fallback_body.presence || '✅ Lead form submitted' if form_data.blank?

    lines = ['✅ Lead form submitted']
    form_data.each do |key, value|
      next if value.blank?

      label = NFM_REPLY_FIELD_LABELS[key] || key.to_s.split('_').map(&:capitalize).join(' ')
      lines << "#{label}: #{value}"
    end
    lines.join("\n")
  end

  def file_content_type(file_type)
    return :image if %w[image sticker].include?(file_type)
    return :audio if %w[audio voice].include?(file_type)
    return :video if ['video'].include?(file_type)
    return :location if ['location'].include?(file_type)
    return :contact if ['contacts'].include?(file_type)

    :file
  end

  def unprocessable_message_type?(message_type)
    %w[reaction ephemeral request_welcome].include?(message_type)
  end

  def processed_waid(waid)
    Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider(waid, :cloud)
  end

  def whatsapp_phone_number(identifier)
    identifier = identifier.to_s
    return if identifier.blank?
    return unless identifier.match?(/\A\d{1,15}\z/)

    identifier
  end

  def error_webhook_event?(message)
    message.key?('errors')
  end

  def log_error(message)
    Rails.logger.warn "Whatsapp Error: #{message['errors'][0]['title']} - contact: #{message['from']}"
  end

  def process_in_reply_to(message)
    @in_reply_to_external_id = message['context']&.[]('id')
  end

  def referral_attributes(message)
    return {} if outgoing_echo

    message[:referral]&.to_h&.deep_stringify_keys || {}
  end

  def find_message_by_source_id(source_id)
    return unless source_id

    @message = Message.find_by(source_id: source_id)
  end

  def lock_message_source_id!
    return false if messages_data.blank?

    Whatsapp::MessageDedupLock.new(messages_data.first[:id]).acquire!
  end
end
