require 'spec_helper'

def travel_to(time)
  around { |example| Timecop.travel(start_of_july + time) { example.run } }
end

describe UpdateBillItems do
  describe "unit specs" do
    let!(:start_of_july) { Time.now.beginning_of_year + 6.months }

    let!(:updater) { UpdateBillItems.new }

    describe "perform", versioning: true do
      let!(:enterprise) { create(:supplier_enterprise, created_at: start_of_july - 1.month, sells: 'any') }

      before do
        allow(Enterprise).to receive(:select) { [enterprise] }
      end

      context "on the first of the month" do
        travel_to(3.hours)

        it "processes the previous month" do
          expect(updater).to receive(:split_for_trial)
          .with(enterprise, start_of_july - 1.month, start_of_july, nil, nil)
          updater.perform
        end
      end

      context "on all other days" do
        travel_to(1.day + 3.hours)

        it "processes the current month up until previous midnight" do
          expect(updater).to receive(:split_for_trial)
          .with(enterprise, start_of_july, start_of_july + 1.day, nil, nil)
          updater.perform
        end
      end

      context "when an enterprise is created before the beginning of the current month" do
        travel_to(28.days)

        context "when no alterations to sells or owner have been made during the current month" do

          it "begins at the start of the month" do
            expect(updater).to receive(:split_for_trial)
            .with(enterprise, start_of_july, start_of_july + 28.days, nil, nil)
            updater.perform
          end
        end

        context "when sells has been changed within the current month" do
          before do
            Timecop.freeze(start_of_july + 10.days) do
              # NOTE: Sells is changed between when order1 and order2 are placed
              enterprise.update_attribute(:sells, 'own')
            end
          end

          travel_to(28.days)

          it "processes each sells period separately" do
            allow(updater).to receive(:split_for_trial).twice
            updater.perform

            expect(updater).to have_received(:split_for_trial)
            .with(enterprise.versions.first.reify, start_of_july, start_of_july + 10.days, nil, nil)

            expect(updater).to have_received(:split_for_trial)
            .with(enterprise, start_of_july + 10.days, start_of_july + 28.days, nil, nil)
          end
        end

        context "when owner has been changed within the current month" do
          let!(:new_owner) { create(:user) }

          before do
            Timecop.freeze(start_of_july + 10.days) do
              # NOTE: Sells is changed between when order1 and order2 are placed
              enterprise.update_attribute(:owner, new_owner)
            end
          end

          travel_to(28.days)

          it "processes each ownership period separately" do
            allow(updater).to receive(:split_for_trial).twice
            updater.perform

            expect(updater).to have_received(:split_for_trial)
            .with(enterprise.versions.first.reify, start_of_july, start_of_july + 10.days, nil, nil)

            expect(updater).to have_received(:split_for_trial)
            .with(enterprise, start_of_july + 10.days, start_of_july + 28.days, nil, nil)
          end
        end

        context "when some other attribute has been changed within the current month" do
          before do
            Timecop.freeze(start_of_july + 10.days) do
              # NOTE: Sells is changed between when order1 and order2 are placed
              enterprise.update_attribute(:name, 'Some New Name')
            end
          end

          travel_to(28.days)

          it "does not create a version, and so does not split the period" do
            expect(enterprise.versions).to eq []
            allow(updater).to receive(:split_for_trial).once
            updater.perform
            expect(updater).to have_received(:split_for_trial)
            .with(enterprise, start_of_july, start_of_july + 28.days, nil, nil)
          end
        end

        context "where sells or owner_id were altered during the previous month (ie. June)" do
          let!(:new_owner) { create(:user) }

          before do
            Timecop.freeze(start_of_july - 20.days) do
              # NOTE: Sells is changed between when order1 and order2 are placed
              enterprise.update_attribute(:sells, 'own')
            end
            Timecop.freeze(start_of_july - 10.days) do
              # NOTE: Sells is changed between when order1 and order2 are placed
              enterprise.update_attribute(:owner, new_owner)
            end
          end

          travel_to(28.days)

          it "ignores those verions" do
            allow(updater).to receive(:split_for_trial).once
            updater.perform
            expect(updater).to have_received(:split_for_trial)
            .with(enterprise, start_of_july, start_of_july + 28.days, nil, nil)
          end
        end
      end

      context "when an enterprise is created during the current month" do
        before do
          enterprise.update_attribute(:created_at, start_of_july + 10.days)
        end

        travel_to(28.days)

        it "begins at the date the enterprise was created" do
          allow(updater).to receive(:split_for_trial).once
          updater.perform
          expect(updater).to have_received(:split_for_trial)
          .with(enterprise, start_of_july + 10.days, start_of_july + 28.days, nil, nil)
        end
      end

      pending "when an enterprise is deleted during the current month" do
        before do
          enterprise.update_attribute(:deleted_at, start_of_july + 20.days)
        end

        travel_to(28.days)

        it "ends at the date the enterprise was deleted" do
          allow(updater).to receive(:split_for_trial)
          updater.perform
          expect(updater).to have_received(:split_for_trial)
          .with(enterprise, start_of_july, start_of_july + 20.days, nil, nil)
        end
      end
    end

    describe "split_for_trial" do
      let!(:enterprise) { double(:enterprise) }
      let(:begins_at) { start_of_july }
      let(:ends_at) { begins_at + 30.days }

      context "when trial_start is nil" do
        let(:trial_start) { nil }
        let(:trial_expiry) { begins_at + 3.days }

        before do
          allow(updater).to receive(:update_bill_item).once
          updater.split_for_trial(enterprise, begins_at, ends_at, trial_start, trial_expiry)
        end

        it "calls update_bill_item once for the entire period" do
          expect(updater).to have_received(:update_bill_item)
          .with(enterprise, begins_at, ends_at, false)
        end
      end

      context "when trial_expiry is nil" do
        let(:trial_start) { begins_at + 3.days }
        let(:trial_expiry) { nil }

        before do
          allow(updater).to receive(:update_bill_item).once
          updater.split_for_trial(enterprise, begins_at, ends_at, trial_start, trial_expiry)
        end

        it "calls update_bill_item once for the entire period" do
          expect(updater).to have_received(:update_bill_item)
          .with(enterprise, begins_at, ends_at, false)
        end
      end

      context "when the trial begins before begins_at" do
        let(:trial_start) { begins_at - 10.days }

        context "and the trial ends before begins_at" do
          let(:trial_expiry) { begins_at - 5.days }

          before do
            allow(updater).to receive(:update_bill_item).once
            updater.split_for_trial(enterprise, begins_at, ends_at, trial_start, trial_expiry)
          end

          it "calls update_bill_item once for the entire period" do
            expect(updater).to have_received(:update_bill_item)
            .with(enterprise, begins_at, ends_at, false)
          end
        end

        context "and the trial ends after begins_at" do
          let(:trial_expiry) { begins_at + 5.days }

          before do
            allow(updater).to receive(:update_bill_item).twice
            updater.split_for_trial(enterprise, begins_at, ends_at, trial_start, trial_expiry)
          end

          it "calls update_bill_item once for the trial period" do
            expect(updater).to have_received(:update_bill_item)
            .with(enterprise, begins_at, trial_expiry, true)
          end

          it "calls update_bill_item once for the non-trial period" do
            expect(updater).to have_received(:update_bill_item)
            .with(enterprise, trial_expiry, ends_at, false)
          end
        end

        context "and the trial ends after ends_at" do
          let(:trial_expiry) { ends_at + 5.days }

          before do
            allow(updater).to receive(:update_bill_item).once
            updater.split_for_trial(enterprise, begins_at, ends_at, trial_start, trial_expiry)
          end

          it "calls update_bill_item once for the entire (trial) period" do
            expect(updater).to have_received(:update_bill_item)
            .with(enterprise, begins_at, ends_at, true)
          end
        end
      end

      context "when the trial begins after begins_at" do
        let(:trial_start) { begins_at + 5.days }

        context "and the trial begins after ends_at" do
          let(:trial_start) { ends_at + 5.days }
          let(:trial_expiry) { ends_at + 10.days }

          before do
            allow(updater).to receive(:update_bill_item).once
            updater.split_for_trial(enterprise, begins_at, ends_at, trial_start, trial_expiry)
          end

          it "calls update_bill_item once for the entire period" do
            expect(updater).to have_received(:update_bill_item)
            .with(enterprise, begins_at, ends_at, false)
          end
        end

        context "and the trial ends before ends_at" do
          let(:trial_expiry) { ends_at - 2.days }

          before do
            allow(updater).to receive(:update_bill_item).exactly(3).times
            updater.split_for_trial(enterprise, begins_at, ends_at, trial_start, trial_expiry)
          end

          it "calls update_bill_item once for the non-trial period before the trial" do
            expect(updater).to have_received(:update_bill_item)
            .with(enterprise, begins_at, trial_start, false)
          end

          it "calls update_bill_item once for the trial period" do
            expect(updater).to have_received(:update_bill_item)
            .with(enterprise, trial_start, trial_expiry, true)
          end

          it "calls update_bill_item once for the non-trial period after the trial" do
            expect(updater).to have_received(:update_bill_item)
            .with(enterprise, trial_expiry, ends_at, false)
          end
        end

        context "and the trial ends after ends_at" do
          let(:trial_expiry) { ends_at + 5.days }

          before do
            allow(updater).to receive(:update_bill_item).twice
            updater.split_for_trial(enterprise, begins_at, ends_at, trial_start, trial_expiry)
          end

          it "calls update_bill_item once for the non-trial period" do
            expect(updater).to have_received(:update_bill_item)
            .with(enterprise, begins_at, trial_start, false)
          end

          it "calls update_bill_item once for the trial period" do
            expect(updater).to have_received(:update_bill_item)
            .with(enterprise, trial_start, ends_at, true)
          end
        end
      end
    end

    describe "update_bill_item" do
      let!(:enterprise) { create(:enterprise, sells: 'any') }

      let!(:existing) { create(:bill_item, enterprise: enterprise, begins_at: start_of_july) }

      context "when arguments match both 'begins_at' and 'enterprise_id' of an existing bill item" do
        it "updates the existing bill item" do
          expect{
            updater.update_bill_item(enterprise, start_of_july, start_of_july + 20.days, false)
          }.to_not change{ BillItem.count }
          existing.reload
          expect(existing.owner_id).to eq enterprise.owner_id
          expect(existing.ends_at).to eq start_of_july + 20.days
          expect(existing.sells).to eq enterprise.sells
          expect(existing.trial).to eq false
        end
      end

      context "when 'begins_at' does not match an existing bill item" do
        before do
          expect{
            updater.update_bill_item(enterprise, start_of_july + 20.days, start_of_july + 30.days, false)
          }.to change{ BillItem.count }.from(1).to(2)
        end

        it "creates a new existing bill item" do
          bill_item = BillItem.last
          expect(bill_item.owner_id).to eq enterprise.owner_id
          expect(bill_item.ends_at).to eq start_of_july + 30.days
          expect(bill_item.sells).to eq enterprise.sells
          expect(bill_item.trial).to eq false
        end
      end

      context "when 'enterprise_id' does not match an existing bill item" do
        let!(:new_enterprise) { create(:enterprise, sells: 'own') }

        before do
          expect{
            updater.update_bill_item(new_enterprise, start_of_july, start_of_july + 20.days, false)
          }.to change{ BillItem.count }.from(1).to(2)
        end

        it "creates a new existing bill item" do
          bill_item = BillItem.last
          expect(bill_item.owner_id).to eq new_enterprise.owner_id
          expect(bill_item.ends_at).to eq start_of_july + 20.days
          expect(bill_item.sells).to eq new_enterprise.sells
          expect(bill_item.trial).to eq false
        end
      end
    end
  end

  describe "validation spec" do
    # Chose july to test with because June has 30 days and so is easy to calculate end date for shop trial
    let!(:start_of_july) { Time.now.beginning_of_year + 6.months }

    let!(:enterprise) { create(:supplier_enterprise, sells: 'any') }

    let!(:original_owner) { enterprise.owner }

    let!(:new_owner) { create(:user) }

    let!(:order1) { create(:order, completed_at: start_of_july + 1.days, distributor: enterprise) }
    let!(:order2) { create(:order, completed_at: start_of_july + 3.days, distributor: enterprise) }
    let!(:order3) { create(:order, completed_at: start_of_july + 5.days, distributor: enterprise) }
    let!(:order4) { create(:order, completed_at: start_of_july + 7.days, distributor: enterprise) }
    let!(:order5) { create(:order, completed_at: start_of_july + 9.days, distributor: enterprise) }
    let!(:order6) { create(:order, completed_at: start_of_july + 11.days, distributor: enterprise) }
    let!(:order7) { create(:order, completed_at: start_of_july + 13.days, distributor: enterprise) }
    let!(:order8) { create(:order, completed_at: start_of_july + 15.days, distributor: enterprise) }
    let!(:order9) { create(:order, completed_at: start_of_july + 17.days, distributor: enterprise) }
    let!(:order10) { create(:order, completed_at: start_of_july + 19.days, distributor: enterprise) }

    before do
      order1.line_items = [ create(:line_item, price: 12.56, order: order1) ]
      order2.line_items = [ create(:line_item, price: 87.44, order: order2) ]
      order3.line_items = [ create(:line_item, price: 50.00, order: order3) ]
      order4.line_items = [ create(:line_item, price: 73.37, order: order4) ]
      order5.line_items = [ create(:line_item, price: 22.46, order: order5) ]
      order6.line_items = [ create(:line_item, price: 44.85, order: order6) ]
      order7.line_items = [ create(:line_item, price: 93.45, order: order7) ]
      order8.line_items = [ create(:line_item, price: 59.38, order: order8) ]
      order9.line_items = [ create(:line_item, price: 47.23, order: order9) ]
      order10.line_items = [ create(:line_item, price: 2.35, order: order10) ]
      [order1, order2, order3, order4, order5, order6, order7, order8, order9, order10].each(&:update!)

      allow(Enterprise).to receive(:select) { [enterprise] }
    end

    context "super complex example", versioning: true do
      before do
        enterprise.update_attribute(:created_at, start_of_july + 2.days)

        Timecop.freeze(start_of_july + 4.days) { enterprise.update_attribute(:sells, 'own') }

        Timecop.freeze(start_of_july + 6.days) { enterprise.update_attribute(:owner, new_owner) }

        enterprise.update_attribute(:shop_trial_start_date, start_of_july + 8.days)

        Timecop.freeze(start_of_july + 10.days) { enterprise.update_attribute(:owner, original_owner) }

        Timecop.freeze(start_of_july + 12.days) { enterprise.update_attribute(:sells, 'any') }

        allow(enterprise).to receive(:shop_trial_expiry) { start_of_july + 14.days }

        Timecop.freeze(start_of_july + 16.days) { enterprise.update_attribute(:sells, 'own') }

        Timecop.freeze(start_of_july + 18.days) { enterprise.update_attribute(:owner, new_owner) }
      end

      travel_to(20.days)

      before do
        UpdateBillItems.new.perform
      end

      let(:bill_items) { BillItem.order(:id) }

      it "creates the correct bill items" do
        expect(bill_items.count).to eq 9

        expect(bill_items.map(&:begins_at)).to eq [
          start_of_july + 2.days,
          start_of_july + 4.days,
          start_of_july + 6.days,
          start_of_july + 8.days,
          start_of_july + 10.days,
          start_of_july + 12.days,
          start_of_july + 14.days,
          start_of_july + 16.days,
          start_of_july + 18.days
        ]

        expect(bill_items.map(&:ends_at)).to eq [
          start_of_july + 4.days,
          start_of_july + 6.days,
          start_of_july + 8.days,
          start_of_july + 10.days,
          start_of_july + 12.days,
          start_of_july + 14.days,
          start_of_july + 16.days,
          start_of_july + 18.days,
          start_of_july + 20.days
        ]

        expect(bill_items.map(&:owner)).to eq [
          original_owner,
          original_owner,
          new_owner,
          new_owner,
          original_owner,
          original_owner,
          original_owner,
          original_owner,
          new_owner
        ]

        expect(bill_items.map(&:sells)).to eq [
          'any',
          'own',
          'own',
          'own',
          'own',
          'any',
          'any',
          'own',
          'own'
        ]

        expect(bill_items.map(&:trial)).to eq [
          false,
          false,
          false,
          true,
          true,
          true,
          false,
          false,
          false
        ]

        expect(bill_items.map(&:turnover)).to eq [
          order2.total,
          order3.total,
          order4.total,
          order5.total,
          order6.total,
          order7.total,
          order8.total,
          order9.total,
          order10.total
        ]
      end
    end
  end
end
