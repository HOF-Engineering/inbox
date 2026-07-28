class ConversationPolicy < ApplicationPolicy
  def index?
    true
  end

  def destroy?
    administrator?
  end

  # `show?` is the only gate for reading and for every single-conversation mutation
  # (toggle_status, assignments, labels, transcript, ...), so it enforces the
  # assigned-only boundary for agents. Team/participant based access is deliberately
  # not honoured here: it would expose conversations the agent is not assigned to.
  def show?
    administrator? || agent_bot? || agent_can_view_conversation?
  end

  private

  def agent_can_view_conversation?
    inbox_access? && assigned_to_user?
  end

  def administrator?
    account_user&.administrator?
  end

  def agent_bot?
    user.is_a?(AgentBot)
  end

  def inbox_access?
    user.inboxes.where(account_id: account&.id).exists?(id: record.inbox_id)
  end

  def assigned_to_user?
    record.assignee_id == user.id
  end
end

ConversationPolicy.prepend_mod_with('ConversationPolicy')
