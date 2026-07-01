class LeadWelcomeFormJob < ApplicationJob
  queue_as :medium

  WELCOME_BODY = 'Thank you for reaching out to HOF Migration. If you\'d like to migrate, please fill this quick form ' \
                 'and our agent will contact you within a few working hours. If you\'re already our client, just drop ' \
                 'your query here and we\'ll get back to you shortly.'.freeze

  def perform(conversation_id)
    return unless self.class.feature_enabled?

    conversation = Conversation.find_by(id: conversation_id)
    return unless eligible_conversation?(conversation)
    return if conversation.additional_attributes['welcome_form_sent']

    channel = conversation.inbox.channel
    phone_number = conversation.contact_inbox.source_id
    return if phone_number.blank?

    response = send_flow_message(channel, phone_number)
    unless flow_message_sent?(response)
      Rails.logger.error("[LeadWelcomeFormJob] Flow message failed: #{response&.body}")
      return
    end

    mark_welcome_form_sent!(conversation)
    add_private_note!(conversation)
  rescue StandardError => e
    Rails.logger.error("[LeadWelcomeFormJob] #{e.class}: #{e.message}")
  end

  def self.feature_enabled?
    ENV['WELCOME_FORM_INBOX_ID'].present? && ENV['WELCOME_FORM_FLOW_ID'].present?
  end

  private

  def eligible_conversation?(conversation)
    return false if conversation.blank?
    return false unless conversation.inbox_id == welcome_form_inbox_id
    return false unless conversation.inbox.channel.is_a?(Channel::Whatsapp)
    return false unless conversation.inbox.channel.provider == 'whatsapp_cloud'

    true
  end

  def welcome_form_inbox_id
    ENV['WELCOME_FORM_INBOX_ID'].to_i
  end

  def send_flow_message(channel, phone_number)
    HTTParty.post(
      messages_url(channel),
      headers: {
        'Authorization' => "Bearer #{channel.provider_config['api_key']}",
        'Content-Type' => 'application/json'
      },
      body: flow_message_payload(phone_number).to_json,
      timeout: 10
    )
  end

  def messages_url(channel)
    base_url = ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
    "#{base_url}/v21.0/#{channel.provider_config['phone_number_id']}/messages"
  end

  def flow_message_payload(phone_number)
    {
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      to: phone_number,
      type: 'interactive',
      interactive: {
        type: 'flow',
        body: { text: WELCOME_BODY },
        action: {
          name: 'flow',
          parameters: {
            flow_message_version: '3',
            flow_token: ENV.fetch('WELCOME_FORM_FLOW_TOKEN', 'hof_lead'),
            flow_id: ENV['WELCOME_FORM_FLOW_ID'],
            flow_cta: 'Fill Form',
            flow_action: 'navigate',
            flow_action_payload: { screen: 'LEAD_FORM' }
          }
        }
      }
    }
  end

  def flow_message_sent?(response)
    parsed = response.parsed_response
    response.success? && parsed.is_a?(Hash) && parsed['error'].blank? && parsed.dig('messages', 0, 'id').present?
  end

  def mark_welcome_form_sent!(conversation)
    conversation.additional_attributes = conversation.additional_attributes.merge('welcome_form_sent' => true)
    conversation.save!
  end

  def add_private_note!(conversation)
    conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      content: '🤖 Auto-sent lead form',
      private: true
    )
  end
end
