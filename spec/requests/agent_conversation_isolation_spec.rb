require 'rails_helper'

# Guarantees the hard per-agent conversation isolation boundary: an agent may only ever read
# or mutate conversations assigned to them. Every path below shares one inbox between two
# agents, so any leak here is a real production leak (web, mobile app and raw API alike).
RSpec.describe 'Agent conversation isolation', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:agent_a) { create(:user, account: account, role: :agent) }
  let(:agent_b) { create(:user, account: account, role: :agent) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  let(:conv_a) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: agent_a)
  end
  let(:conv_b) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: agent_b)
  end
  let(:conv_unassigned) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: nil)
  end

  let(:agent_a_headers) { agent_a.create_new_auth_token }
  let(:admin_headers) { administrator.create_new_auth_token }

  before do
    create(:inbox_member, user: agent_a, inbox: inbox)
    create(:inbox_member, user: agent_b, inbox: inbox)
    create(:inbox_member, user: administrator, inbox: inbox)

    create(:message, account: account, inbox: inbox, conversation: conv_a, message_type: :incoming, content: 'needle alpha')
    create(:message, account: account, inbox: inbox, conversation: conv_b, message_type: :incoming, content: 'needle bravo')
    create(:message, account: account, inbox: inbox, conversation: conv_unassigned, message_type: :incoming, content: 'needle charlie')
  end

  def returned_display_ids
    response.parsed_body['data']['payload'].pluck('id')
  end

  # `filter`, `search` and the global search endpoints render `payload` at the root.
  def payload_ids
    response.parsed_body['payload'].pluck('id')
  end

  describe 'GET /api/v1/accounts/:account_id/conversations' do
    [nil, 'all', 'unassigned', 'assigned', 'me'].each do |assignee_type|
      it "only returns the agent's own conversations for assignee_type=#{assignee_type.inspect}" do
        params = { status: 'all' }
        params[:assignee_type] = assignee_type if assignee_type

        get "/api/v1/accounts/#{account.id}/conversations", headers: agent_a_headers, params: params, as: :json

        expect(response).to have_http_status(:success)
        expect(returned_display_ids).not_to include(conv_b.display_id, conv_unassigned.display_id)
      end
    end

    it 'returns the agent own conversation' do
      get "/api/v1/accounts/#{account.id}/conversations", headers: agent_a_headers, params: { status: 'all' }, as: :json

      expect(returned_display_ids).to contain_exactly(conv_a.display_id)
    end

    it 'ignores an inbox_id targeting a shared inbox' do
      get "/api/v1/accounts/#{account.id}/conversations",
          headers: agent_a_headers, params: { status: 'all', assignee_type: 'all', inbox_id: inbox.id }, as: :json

      expect(returned_display_ids).to contain_exactly(conv_a.display_id)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/conversations/meta' do
    it 'does not count other agents or unassigned conversations' do
      conv_a
      conv_b
      conv_unassigned

      get "/api/v1/accounts/#{account.id}/conversations/meta", headers: agent_a_headers, params: { status: 'all' }, as: :json

      counts = response.parsed_body['meta']
      expect(counts['mine_count']).to eq(1)
      expect(counts['all_count']).to eq(1)
      expect(counts['unassigned_count']).to eq(0)
    end
  end

  describe 'POST /api/v1/accounts/:account_id/conversations/filter' do
    it 'does not leak conversations assigned to another agent' do
      payload = [{ attribute_key: 'assignee_id', filter_operator: 'equal_to', values: [agent_b.id], query_operator: nil }]

      post "/api/v1/accounts/#{account.id}/conversations/filter", headers: agent_a_headers, params: { payload: payload }, as: :json

      expect(response).to have_http_status(:success)
      expect(payload_ids).to be_empty
    end

    it 'does not leak conversations when filtering by inbox' do
      payload = [{ attribute_key: 'inbox_id', filter_operator: 'equal_to', values: [inbox.id], query_operator: nil }]

      post "/api/v1/accounts/#{account.id}/conversations/filter", headers: agent_a_headers, params: { payload: payload }, as: :json

      expect(payload_ids).to contain_exactly(conv_a.display_id)
    end

    it 'does not leak conversations when filtering by status' do
      payload = [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: nil }]

      post "/api/v1/accounts/#{account.id}/conversations/filter", headers: agent_a_headers, params: { payload: payload }, as: :json

      expect(payload_ids).to contain_exactly(conv_a.display_id)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/conversations/search' do
    it 'does not leak other agents conversations' do
      conv_a
      conv_b
      conv_unassigned

      get "/api/v1/accounts/#{account.id}/conversations/search",
          headers: agent_a_headers, params: { q: 'needle', status: 'all' }, as: :json

      expect(response).to have_http_status(:success)
      expect(payload_ids).to contain_exactly(conv_a.display_id)
    end
  end

  describe 'single conversation reads' do
    # 404 rather than 401 on purpose: the mobile app signs the agent out on a 401, and a
    # 404 does not confirm that the conversation exists.
    it 'denies showing another agents conversation without signing the agent out' do
      get "/api/v1/accounts/#{account.id}/conversations/#{conv_b.display_id}", headers: agent_a_headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response).not_to have_http_status(:unauthorized)
    end

    it 'denies showing an unassigned conversation' do
      get "/api/v1/accounts/#{account.id}/conversations/#{conv_unassigned.display_id}", headers: agent_a_headers, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'allows showing its own conversation' do
      get "/api/v1/accounts/#{account.id}/conversations/#{conv_a.display_id}", headers: agent_a_headers, as: :json

      expect(response).to have_http_status(:success)
    end

    it 'denies reading messages of another agents conversation' do
      get "/api/v1/accounts/#{account.id}/conversations/#{conv_b.display_id}/messages", headers: agent_a_headers, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('needle bravo')
    end

    it 'denies reading attachments of another agents conversation' do
      get "/api/v1/accounts/#{account.id}/conversations/#{conv_b.display_id}/attachments", headers: agent_a_headers, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # This is the "My Inbox" notification list. Notifications outlive an assignee change, so
  # they have to be filtered at read time, not just gated when they are created.
  describe 'notification list' do
    def notify(user, conversation)
      create(:notification, account: account, user: user, primary_actor: conversation, notification_type: 'conversation_creation')
    end

    def listed_notification_ids
      response.parsed_body['data']['payload'].pluck('id')
    end

    it 'only lists notifications for conversations the agent can open' do
      own = notify(agent_a, conv_a)
      other_agents = notify(agent_a, conv_b)
      unassigned = notify(agent_a, conv_unassigned)

      get "/api/v1/accounts/#{account.id}/notifications", headers: agent_a_headers, as: :json

      expect(response).to have_http_status(:success)
      expect(listed_notification_ids).to contain_exactly(own.id)
      expect(listed_notification_ids).not_to include(other_agents.id, unassigned.id)
    end

    it 'excludes them from the unread count badge' do
      notify(agent_a, conv_a)
      notify(agent_a, conv_b)
      notify(agent_a, conv_unassigned)

      get "/api/v1/accounts/#{account.id}/notifications/unread_count", headers: agent_a_headers, as: :json

      expect(response.parsed_body).to eq(1)
    end

    it 'hides a notification once the conversation is reassigned away from the agent' do
      notify(agent_a, conv_a)
      conv_a.update!(assignee: agent_b)

      get "/api/v1/accounts/#{account.id}/notifications", headers: agent_a_headers, as: :json

      expect(listed_notification_ids).to be_empty
    end

    it 'still lists everything for an administrator' do
      notify(administrator, conv_a)
      notify(administrator, conv_b)
      notify(administrator, conv_unassigned)

      get "/api/v1/accounts/#{account.id}/notifications", headers: admin_headers, as: :json

      expect(listed_notification_ids.length).to eq(3)
    end
  end

  # An administrator reviewing a conversation must not steal the owner's unread badge:
  # `agent_last_seen_at` is a single shared column that drives unread_count for everybody.
  describe 'read state when a non-assignee reviews a conversation' do
    it 'leaves the conversation unread when an administrator only opens it' do
      expect(conv_a.unread_incoming_messages.count).to eq(1)
      seen_before = conv_a.agent_last_seen_at

      post "/api/v1/accounts/#{account.id}/conversations/#{conv_a.display_id}/update_last_seen",
           headers: admin_headers, as: :json

      expect(response).to have_http_status(:success)
      expect(conv_a.reload.agent_last_seen_at).to eq(seen_before)
      expect(conv_a.unread_incoming_messages.count).to eq(1)
    end

    it 'marks it read once the administrator actually replies' do
      post "/api/v1/accounts/#{account.id}/conversations/#{conv_a.display_id}/update_last_seen",
           headers: admin_headers, as: :json
      post "/api/v1/accounts/#{account.id}/conversations/#{conv_a.display_id}/messages",
           params: { content: 'stepping in for you' }, headers: admin_headers, as: :json

      expect(response).to have_http_status(:success)
      expect(conv_a.reload.agent_last_seen_at).to be_present
      expect(conv_a.unread_incoming_messages.count).to eq(0)
    end

    it 'does not mark it read when the administrator only leaves a private note' do
      seen_before = conv_a.agent_last_seen_at

      post "/api/v1/accounts/#{account.id}/conversations/#{conv_a.display_id}/messages",
           params: { content: 'internal note', private: true }, headers: admin_headers, as: :json

      expect(conv_a.reload.agent_last_seen_at).to eq(seen_before)
      expect(conv_a.unread_incoming_messages.count).to eq(1)
    end

    it 'still marks it read when the assignee opens it' do
      post "/api/v1/accounts/#{account.id}/conversations/#{conv_a.display_id}/update_last_seen",
           headers: agent_a_headers, as: :json

      expect(response).to have_http_status(:success)
      expect(conv_a.reload.agent_last_seen_at).to be_present
      expect(conv_a.unread_incoming_messages.count).to eq(0)
    end
  end

  describe 'mutating actions on another agents conversation' do
    it 'denies every single-conversation mutation' do
      requests = [
        [:post, "conversations/#{conv_b.display_id}/toggle_status", { status: 'resolved' }],
        [:post, "conversations/#{conv_b.display_id}/toggle_priority", { priority: 'urgent' }],
        [:post, "conversations/#{conv_b.display_id}/assignments", { assignee_id: agent_a.id }],
        [:post, "conversations/#{conv_b.display_id}/labels", { labels: %w[leaked] }],
        [:post, "conversations/#{conv_b.display_id}/custom_attributes", { custom_attributes: { leaked: true } }],
        [:post, "conversations/#{conv_b.display_id}/transcript", { email: 'leak@example.com' }],
        [:post, "conversations/#{conv_b.display_id}/update_last_seen", {}],
        [:post, "conversations/#{conv_b.display_id}/unread", {}],
        [:post, "conversations/#{conv_b.display_id}/mute", {}],
        [:post, "conversations/#{conv_b.display_id}/messages", { content: 'leaked reply' }],
        [:patch, "conversations/#{conv_b.display_id}", { priority: 'urgent' }],
        [:delete, "conversations/#{conv_b.display_id}", {}]
      ]

      requests.each do |verb, path, payload|
        public_send(verb, "/api/v1/accounts/#{account.id}/#{path}", headers: agent_a_headers, params: payload, as: :json)

        expect(response).to have_http_status(:not_found), "expected #{verb.upcase} #{path} to be denied, got #{response.status}"
      end

      conv_b.reload
      expect(conv_b.status).to eq('open')
      expect(conv_b.priority).to be_nil
      expect(conv_b.assignee_id).to eq(agent_b.id)
      expect(conv_b.label_list).to be_empty
      expect(conv_b.messages.pluck(:content)).not_to include('leaked reply')
    end
  end

  describe 'GET /api/v1/accounts/:account_id/contacts/:contact_id/conversations' do
    it 'only returns the agents own conversations for the contact' do
      conv_a
      conv_b
      conv_unassigned

      get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations", headers: agent_a_headers, as: :json

      expect(response.parsed_body['payload'].pluck('id')).to contain_exactly(conv_a.display_id)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/contacts/:contact_id/attachments' do
    let!(:leaked_attachment_message) do
      message = create(:message, account: account, inbox: inbox, conversation: conv_b, message_type: :incoming)
      message.attachments.create!(account_id: account.id, file_type: :image)
      message
    end

    it 'does not return attachments from another agents conversation' do
      get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/attachments", headers: agent_a_headers, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].pluck('message_id')).not_to include(leaked_attachment_message.id)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/conversations/unread_counts' do
    before { account.enable_features!('conversation_unread_counts') }

    it 'only counts the agents own unread conversations' do
      conv_a
      conv_b
      conv_unassigned

      get "/api/v1/accounts/#{account.id}/conversations/unread_counts", headers: agent_a_headers, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload']['all_count']).to eq(1)
    end
  end

  describe 'POST /api/v1/accounts/:account_id/bulk_actions' do
    it 'rejects bulk actions targeting another agents conversation' do
      post "/api/v1/accounts/#{account.id}/bulk_actions",
           headers: agent_a_headers,
           params: { type: 'Conversation', ids: [conv_b.display_id], fields: { status: 'resolved' } },
           as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(conv_b.reload.status).to eq('open')
    end

    it 'rejects bulk actions mixing own and other agents conversations' do
      post "/api/v1/accounts/#{account.id}/bulk_actions",
           headers: agent_a_headers,
           params: { type: 'Conversation', ids: [conv_a.display_id, conv_unassigned.display_id], fields: { status: 'resolved' } },
           as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(conv_unassigned.reload.status).to eq('open')
    end

    it 'allows bulk actions on its own conversations' do
      post "/api/v1/accounts/#{account.id}/bulk_actions",
           headers: agent_a_headers,
           params: { type: 'Conversation', ids: [conv_a.display_id], fields: { status: 'resolved' } },
           as: :json

      expect(response).to have_http_status(:success)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/search' do
    it 'does not leak conversations or messages from other agents' do
      conv_a
      conv_b
      conv_unassigned

      get "/api/v1/accounts/#{account.id}/search", headers: agent_a_headers, params: { q: contact.name }, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload']['conversations'].pluck('id')).to contain_exactly(conv_a.display_id)
    end

    it 'does not leak message content from other agents' do
      get "/api/v1/accounts/#{account.id}/search", headers: agent_a_headers, params: { q: 'needle' }, as: :json

      expect(response.parsed_body['payload']['messages'].pluck('content')).to contain_exactly('needle alpha')
    end

    it 'does not leak messages on the dedicated message search endpoint' do
      get "/api/v1/accounts/#{account.id}/search/messages", headers: agent_a_headers, params: { q: 'needle' }, as: :json

      expect(response.parsed_body['payload']['messages'].pluck('content')).to contain_exactly('needle alpha')
    end

    it 'does not leak conversations on the dedicated conversation search endpoint' do
      conv_a
      conv_b
      conv_unassigned

      get "/api/v1/accounts/#{account.id}/search/conversations", headers: agent_a_headers, params: { q: contact.name }, as: :json

      expect(response.parsed_body['payload']['conversations'].pluck('id')).to contain_exactly(conv_a.display_id)
    end
  end

  describe 'administrator visibility' do
    it 'still sees every conversation in the list' do
      conv_a
      conv_b
      conv_unassigned

      get "/api/v1/accounts/#{account.id}/conversations", headers: admin_headers, params: { status: 'all', assignee_type: 'all' }, as: :json

      expect(returned_display_ids).to contain_exactly(conv_a.display_id, conv_b.display_id, conv_unassigned.display_id)
    end

    it 'still reports unassigned counts in meta' do
      conv_a
      conv_b
      conv_unassigned

      get "/api/v1/accounts/#{account.id}/conversations/meta", headers: admin_headers, params: { status: 'all' }, as: :json

      counts = response.parsed_body['meta']
      expect(counts['all_count']).to eq(3)
      expect(counts['unassigned_count']).to eq(1)
    end

    it 'still reads a conversation it is not assigned to' do
      get "/api/v1/accounts/#{account.id}/conversations/#{conv_b.display_id}", headers: admin_headers, as: :json

      expect(response).to have_http_status(:success)
    end

    it 'still reads messages of a conversation it is not assigned to' do
      get "/api/v1/accounts/#{account.id}/conversations/#{conv_b.display_id}/messages", headers: admin_headers, as: :json

      expect(response).to have_http_status(:success)
      expect(response.body).to include('needle bravo')
    end

    it 'still finds every conversation through global search' do
      conv_a
      conv_b
      conv_unassigned

      get "/api/v1/accounts/#{account.id}/search", headers: admin_headers, params: { q: contact.name }, as: :json

      expect(response.parsed_body['payload']['conversations'].pluck('id'))
        .to include(conv_a.display_id, conv_b.display_id, conv_unassigned.display_id)
    end

    it 'still finds every message through global search' do
      get "/api/v1/accounts/#{account.id}/search", headers: admin_headers, params: { q: 'needle' }, as: :json

      expect(response.parsed_body['payload']['messages'].pluck('content'))
        .to include('needle alpha', 'needle bravo', 'needle charlie')
    end

    it 'still performs bulk actions on any conversation' do
      post "/api/v1/accounts/#{account.id}/bulk_actions",
           headers: admin_headers,
           params: { type: 'Conversation', ids: [conv_b.display_id, conv_unassigned.display_id], fields: { status: 'resolved' } },
           as: :json

      expect(response).to have_http_status(:success)
    end
  end

  describe 'realtime broadcast audience' do
    let(:listener) { ActionCableListener.instance }

    it 'excludes another agent from a message created on conv_a' do
      message = create(:message, account: account, inbox: inbox, conversation: conv_a, message_type: :incoming, content: 'realtime alpha')
      event = Events::Base.new('message.created', Time.zone.now, message: message)

      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, _event_name, _payload|
        expect(tokens).to include(agent_a.pubsub_token, administrator.pubsub_token)
        expect(tokens).not_to include(agent_b.pubsub_token)
      end

      listener.message_created(event)
    end

    it 'excludes every agent from a message created on an unassigned conversation' do
      message = create(:message, account: account, inbox: inbox, conversation: conv_unassigned, message_type: :incoming, content: 'realtime')
      event = Events::Base.new('message.created', Time.zone.now, message: message)

      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, _event_name, _payload|
        expect(tokens).to include(administrator.pubsub_token)
        expect(tokens).not_to include(agent_a.pubsub_token, agent_b.pubsub_token)
      end

      listener.message_created(event)
    end

    it 'notifies the previous assignee on an assignee change so it leaves their list' do
      conv_a.update!(assignee: agent_b)
      event = Events::Base.new(
        'assignee.changed', Time.zone.now,
        conversation: conv_a, changed_attributes: { 'assignee_id' => [agent_a.id, agent_b.id] }
      )

      expect(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, _event_name, _payload|
        expect(tokens).to include(agent_a.pubsub_token, agent_b.pubsub_token, administrator.pubsub_token)
      end

      listener.assignee_changed(event)
    end
  end
end
