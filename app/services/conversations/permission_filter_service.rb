class Conversations::PermissionFilterService
  attr_reader :conversations, :user, :account

  def initialize(conversations, user, account)
    @conversations = conversations
    @user = user
    @account = account
  end

  def perform
    return conversations if user_role == 'administrator'

    restrict_to_assigned(accessible_conversations)
  end

  private

  # SECURITY-CRITICAL: agents are limited to conversations assigned to them.
  # Any override of `perform` (see the enterprise overlay) must pass its final
  # relation through this helper so it can never widen access.
  def restrict_to_assigned(scope)
    scope.visible_to_agent(user)
  end

  def accessible_conversations
    conversations.where(inbox: user.inboxes.where(account_id: account.id))
  end

  def account_user
    AccountUser.find_by(account_id: account.id, user_id: user.id)
  end

  def user_role
    account_user&.role
  end
end

Conversations::PermissionFilterService.prepend_mod_with('Conversations::PermissionFilterService')
