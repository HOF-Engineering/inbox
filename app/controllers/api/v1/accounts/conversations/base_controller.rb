class Api::V1::Accounts::Conversations::BaseController < Api::V1::Accounts::BaseController
  include ConversationScopeHelper

  before_action :conversation

  private

  def conversation
    @conversation ||= permitted_conversations.find_by!(display_id: params[:conversation_id])
    authorize @conversation, :show?
  end
end
