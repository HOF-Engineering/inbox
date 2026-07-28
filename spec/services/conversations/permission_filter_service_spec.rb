require 'rails_helper'

RSpec.describe Conversations::PermissionFilterService do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:another_agent) { create(:user, account: account, role: :agent) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let!(:another_conversation) { create(:conversation, account: account, inbox: inbox, assignee: another_agent) }
  let!(:unassigned_conversation) { create(:conversation, account: account, inbox: inbox, assignee: nil) }

  # This inbox_member is used to establish the agent's access to the inbox
  before { create(:inbox_member, user: agent, inbox: inbox) }

  describe '#perform' do
    context 'when user is an administrator' do
      it 'returns all conversations' do
        result = described_class.new(
          account.conversations,
          admin,
          account
        ).perform

        expect(result).to include(conversation, another_conversation, unassigned_conversation)
        expect(result.count).to eq(3)
      end
    end

    context 'when user is an agent' do
      it 'returns only the conversations assigned to the agent' do
        result = described_class.new(
          account.conversations,
          agent,
          account
        ).perform

        expect(result).to contain_exactly(conversation)
      end

      it 'excludes conversations from inboxes the agent is not a member of' do
        other_inbox = create(:inbox, account: account)
        other_inbox_conversation = create(:conversation, account: account, inbox: other_inbox, assignee: agent)

        result = described_class.new(account.conversations, agent, account).perform

        expect(result).not_to include(other_inbox_conversation)
      end
    end
  end
end
