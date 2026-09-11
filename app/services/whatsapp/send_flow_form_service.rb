class Whatsapp::SendFlowFormService
  Result = Struct.new(:success?, :error, keyword_init: true)

  # Mirrors the payloads already used by LeadWelcomeFormJob / PackWelcomeFormJob,
  # so an agent can trigger the same WhatsApp Flow on demand instead of only on
  # the very first inbound message.
  FORM_CONFIGS = [
    {
      inbox_env: 'WELCOME_FORM_INBOX_ID',
      flow_id_env: 'WELCOME_FORM_FLOW_ID',
      flow_token_env: 'WELCOME_FORM_FLOW_TOKEN',
      flow_token_default: 'hof_lead',
      screen: 'LEAD_FORM',
      body: LeadWelcomeFormJob::WELCOME_BODY,
      note: '🤖 Form sent manually by agent'
    }.freeze,
    {
      inbox_env: 'PACK_FORM_INBOX_ID',
      flow_id_env: 'PACK_FORM_FLOW_ID',
      flow_token_env: 'PACK_FORM_FLOW_TOKEN',
      flow_token_default: 'hof_pack',
      screen_env: 'PACK_FORM_SCREEN',
      screen_default: 'INTAKE_FORM',
      body: PackWelcomeFormJob::WELCOME_BODY,
      note: '🤖 Form sent manually by agent'
    }.freeze
  ].freeze

  def initialize(conversation:)
    @conversation = conversation
  end

  def perform
    config = matching_config
    return failure('No intake form is configured for this inbox') unless config
    return failure('This action is only available for WhatsApp Cloud inboxes') unless whatsapp_cloud_channel?

    phone_number = @conversation.contact_inbox&.source_id
    return failure('Contact has no WhatsApp number') if phone_number.blank?

    response = send_flow_message(phone_number, config)
    return failure(error_from(response)) unless flow_message_sent?(response)

    create_note!(config)
    Result.new(success?: true, error: nil)
  end

  private

  def matching_config
    FORM_CONFIGS.find do |cfg|
      ENV[cfg[:inbox_env]].present? && ENV[cfg[:flow_id_env]].present? &&
        @conversation.inbox_id == ENV[cfg[:inbox_env]].to_i
    end
  end

  def channel
    @channel ||= @conversation.inbox.channel
  end

  def whatsapp_cloud_channel?
    channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
  end

  def send_flow_message(phone_number, config)
    HTTParty.post(
      messages_url,
      headers: {
        'Authorization' => "Bearer #{channel.provider_config['api_key']}",
        'Content-Type' => 'application/json'
      },
      body: flow_message_payload(phone_number, config).to_json,
      timeout: 10
    )
  end

  def messages_url
    base_url = ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
    "#{base_url}/v21.0/#{channel.provider_config['phone_number_id']}/messages"
  end

  def flow_message_payload(phone_number, config)
    screen = config[:screen] || ENV.fetch(config[:screen_env], config[:screen_default])

    {
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      to: phone_number,
      type: 'interactive',
      interactive: {
        type: 'flow',
        body: { text: config[:body] },
        action: {
          name: 'flow',
          parameters: {
            flow_message_version: '3',
            flow_token: ENV.fetch(config[:flow_token_env], config[:flow_token_default]),
            flow_id: ENV[config[:flow_id_env]],
            flow_cta: 'Fill Form',
            flow_action: 'navigate',
            flow_action_payload: { screen: screen }
          }
        }
      }
    }
  end

  def flow_message_sent?(response)
    parsed = response.parsed_response
    response.success? && parsed.is_a?(Hash) && parsed['error'].blank? && parsed.dig('messages', 0, 'id').present?
  end

  def error_from(response)
    parsed = response&.parsed_response
    return 'WhatsApp rejected the form message' unless parsed.is_a?(Hash)

    parsed.dig('error', 'error_data', 'details') || parsed.dig('error', 'message') || 'WhatsApp rejected the form message'
  end

  def create_note!(config)
    @conversation.messages.create!(
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      message_type: :outgoing,
      content: config[:note],
      private: true
    )
  end

  def failure(error)
    Result.new(success?: false, error: error)
  end
end
