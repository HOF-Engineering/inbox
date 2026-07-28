module Enterprise::ConversationPolicy
  CONVERSATION_PERMISSIONS = %w[
    conversation_manage
    conversation_unassigned_manage
    conversation_participating_manage
  ].freeze

  # `super` already restricts agents to conversations assigned to them, so a custom
  # role can only narrow access further here (by not carrying any conversation
  # permission at all) - never widen it.
  def show?
    return false unless super
    return true unless custom_role_permissions?

    custom_role_permissions.intersect?(CONVERSATION_PERMISSIONS)
  end

  private

  def custom_role_permissions?
    account_user&.custom_role_id.present?
  end

  def custom_role_permissions
    account_user&.custom_role&.permissions || []
  end
end
