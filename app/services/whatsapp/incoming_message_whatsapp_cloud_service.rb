# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/

class Whatsapp::IncomingMessageWhatsappCloudService < Whatsapp::IncomingMessageBaseService
  private

  def create_regular_message(message)
    super
    return unless nfm_reply?(message)

    form_data = parse_nfm_reply_json(message)
    return if form_data.blank?

    update_contact_from_nfm_reply(form_data)
    enqueue_lead_sheet_forward(form_data)
  end

  def message_content_attributes(message)
    super.tap do |content_attrs|
      next unless nfm_reply?(message)

      form_data = parse_nfm_reply_json(message)
      content_attrs[:submitted_form] = form_data if form_data.present?
    end
  end

  def update_contact_from_nfm_reply(form_data)
    attrs = form_data.slice('email', 'country', 'interested_in', 'occupation').compact_blank
    @contact.custom_attributes = (@contact.custom_attributes || {}).merge(attrs)
    @contact.name = form_data['full_name'] if @contact.name.blank? && form_data['full_name'].present?
    @contact.email = form_data['email'] if @contact.email.blank? && form_data['email'].present?
    @contact.save!
  rescue StandardError => e
    Rails.logger.error("[Whatsapp] Failed to update contact from nfm_reply: #{e.message}")
  end

  def enqueue_lead_sheet_forward(form_data)
    return if ENV['LEAD_SHEET_WEBHOOK_URL'].blank?

    LeadSheetForwardJob.perform_later(
      full_name: form_data['full_name'],
      phone: @contact.phone_number,
      email: form_data['email'],
      country: form_data['country'],
      interested_in: form_data['interested_in'],
      occupation: form_data['occupation']
    )
  end

  def processed_params
    @processed_params ||= params[:entry].try(:first).try(:[], 'changes').try(:first).try(:[], 'value')
  end

  def download_attachment_file(attachment_payload)
    url_response = HTTParty.get(
      inbox.channel.media_url(attachment_payload[:id]),
      headers: inbox.channel.api_headers
    )

    # This url response will be failure if the access token has expired.
    inbox.channel.authorization_error! if url_response.unauthorized?

    return unless url_response.success?

    downloaded_file = Down.download(url_response.parsed_response['url'], headers: inbox.channel.api_headers)
    # WhatsApp Cloud sends the original filename in the payload; preserve it so accented
    # names keep their correct extension instead of relying on the mangled remote metadata.
    filename = attachment_payload[:filename]
    downloaded_file.define_singleton_method(:original_filename) { filename } if filename.present?
    downloaded_file
  end
end
