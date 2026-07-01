class LeadSheetForwardJob < ApplicationJob
  queue_as :medium

  def perform(payload)
    url = ENV['LEAD_SHEET_WEBHOOK_URL']
    return if url.blank?

    HTTParty.post(
      url,
      body: payload.compact.to_json,
      headers: { 'Content-Type' => 'application/json' },
      timeout: 10
    )
  rescue StandardError => e
    Rails.logger.error("[LeadSheetForwardJob] #{e.class}: #{e.message}")
  end
end
