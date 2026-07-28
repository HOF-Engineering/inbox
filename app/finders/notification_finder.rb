class NotificationFinder
  attr_reader :current_user, :current_account, :params

  RESULTS_PER_PAGE = 15

  def initialize(current_user, current_account, params = {})
    @current_user = current_user
    @current_account = current_account
    @params = params
    set_up
  end

  def notifications
    @notifications.page(current_page).per(RESULTS_PER_PAGE).order(last_activity_at: sort_order)
  end

  def unread_count
    if type_included?('read')
      # If we're including read notifications, filter to unread
      @notifications.where(read_at: nil).count
    else
      # Already filtered to unread notifications, just count
      @notifications.count
    end
  end

  def count
    @notifications.count
  end

  private

  def set_up
    find_all_notifications
    filter_by_conversation_access
    filter_snoozed_notifications
    filter_read_notifications
  end

  def find_all_notifications
    @notifications = current_user.notifications.where(account_id: @current_account.id)
  end

  # SECURITY-CRITICAL: every notification points at a conversation (Notification::PRIMARY_ACTORS),
  # so notifications for conversations the user can no longer open must not surface at all.
  # This covers the list, the counts and the unread badge, and it also hides notifications that
  # became stale because the conversation was reassigned after the notification was created.
  def filter_by_conversation_access
    @notifications = @notifications.where(
      primary_actor_type: 'Conversation',
      primary_actor_id: accessible_conversations.select(:id)
    )
  end

  def accessible_conversations
    ::Conversations::PermissionFilterService.new(@current_account.conversations, current_user, @current_account).perform
  end

  def filter_snoozed_notifications
    @notifications = @notifications.where(snoozed_until: nil) unless type_included?('snoozed')
  end

  def filter_read_notifications
    @notifications = @notifications.where(read_at: nil) unless type_included?('read')
  end

  def type_included?(type)
    (params[:includes] || []).include?(type)
  end

  def current_page
    params[:page] || 1
  end

  def sort_order
    params[:sort_order] || :desc
  end
end
