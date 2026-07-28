module ConversationScopeHelper
  extend ActiveSupport::Concern

  private

  # SECURITY-CRITICAL: single conversation lookups resolve inside the caller's permitted
  # scope, so an inaccessible conversation raises RecordNotFound (404) instead of a Pundit
  # denial (401). The mobile app treats a 401 as an expired session and signs the agent out,
  # and a 404 also avoids confirming that the conversation exists. Callers still run
  # `authorize @conversation, :show?` as the policy gate.
  #
  # Current.user is an AgentBot for token authenticated bot requests, which the permission
  # filter cannot resolve, so bots keep the account scope and rely on `show?` alone.
  def permitted_conversations
    return Current.account.conversations unless Current.user.is_a?(User)

    ::Conversations::PermissionFilterService.new(Current.account.conversations, Current.user, Current.account).perform
  end
end
