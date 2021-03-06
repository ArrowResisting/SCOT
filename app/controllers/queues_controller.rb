class QueuesController < ApplicationController
  before_action :check_admin, only: [:review_spam_reviews, :review_dedupe_reviews, :review_suggested_edit_reviews]
  before_action :check_triage

  def dedupe
    @original = RescueRequest.left_joins(:dedupe_reviews).where(rescue_requests: { dupe_of: nil })
                             .where('dedupe_reviews.user_id IS NULL OR dedupe_reviews.user_id != ?', current_user.id)
                             .where("dedupe_reviews.outcome IS NULL OR dedupe_reviews.outcome != 'skip'").first
    if @original.nil?
      flash[:info] = 'There are no more records to deduplicate!'
      redirect_to :disasters
    else
      @suggested_duplicates = []
      while @suggested_duplicates.empty?
        @original = RescueRequest.left_joins(:dedupe_reviews).where(rescue_requests: { dupe_of: nil })
                                 .where('dedupe_reviews.user_id IS NULL OR dedupe_reviews.user_id != ?', current_user.id)
                                 .where("dedupe_reviews.outcome IS NULL OR dedupe_reviews.outcome != 'skip'").first
        break if @original.nil?
        @disaster = @original.disaster
        possible_duplicate_columns = %w[twitter phone email medical_conditions extra_details street_address]
        filtered_request = @original.attributes.select { |col, _val| possible_duplicate_columns.include? col }
        conditions = filtered_request.map { |col, val| " #{col} LIKE #{ActiveRecord::Base.connection.quote("%#{val}%")}" unless val.to_s.empty? }
                                     .reject { |i| i.to_s.empty? }.join(' OR ')
        @suggested_duplicates = conditions.empty? ? [] : RescueRequest.where(conditions).where.not(id: @original.id)
        @original.update(dupe_of: 0) if @suggested_duplicates.empty?
      end
      if @original.nil?
        flash[:info] = 'There are no more records to deduplicate!'
        redirect_to :disasters
      end
    end
  end

  # Dupe_of 0 means that it's a new record
  def dedupe_complete
    original = RescueRequest.find(params[:rescue_request_id])
    if params[:dupe_of]
      target = RescueRequest.find(params[:dupe_of])
      until target.dupe_of.nil? || target.dupe_of == 0
        target = RescueRequest.find(target.dupe_of)
      end
      target.update(dupe_of: 0) if target.dupe_of.nil?
      current_user.dedupe_reviews.create(rescue_request_id: original.id, outcome: 'dupe', dupe_of_id: target.id,
                                         suggested_duplicates: params[:suggested_duplicates])
      note = "#{current_user.username} closed this as a duplicate of ##{target.id}. It was previously #{original.request_status.name}."
      original.case_notes.create(content: note)
      original.update request_status: RequestStatus.find_by(name: 'Closed'), dupe_of: params[:dupe_of]
    elsif params[:skip]
      current_user.dedupe_reviews.create(rescue_request_id: original.id, outcome: 'skip', suggested_duplicates: params[:suggested_duplicates])
    elsif params[:not]
      current_user.dedupe_reviews.create(rescue_request_id: original.id, outcome: 'not', dupe_of_id: 0,
                                         suggested_duplicates: params[:suggested_duplicates])
      original.update(dupe_of: 0)
    end
    redirect_to action: :dedupe
  end

  def review_dedupe_reviews
    @reviews = DedupeReview.all
  end

  def spam
    @rescue_request = RescueRequest.find_by(spam: nil)
    if @rescue_request.nil?
      flash[:info] = 'There are no records to spam check!'
      redirect_to :disasters
    else
      @disaster = @rescue_request.disaster
    end
  end

  def spam_complete
    parse = { spam: true, not: false, skip: nil }
    current_user.spam_reviews.create(rescue_request_id: params[:rescue_request_id], outcome: params[:outcome])
    RescueRequest.find(params[:rescue_request_id]).update(spam: parse[params[:outcome].to_sym])
    redirect_to action: :spam
  end

  def review_spam_reviews
    @reviews = SpamReview.all
  end

  def suggested_edit
    @suggested_edit = SuggestedEdit.find_by(reviewed_by: nil)
    if @suggested_edit.nil?
      flash[:info] = 'There are no suggested edits to review!'
      redirect_to :disasters
    else
      @disaster = @suggested_edit.resource.disaster.id
      @request = @suggested_edit.resource
    end
  end

  def suggested_edit_complete
    @suggested_edit = SuggestedEdit.find(params[:suggested_edit_id])
    @disaster = @suggested_edit.resource.disaster.id
    if params[:reject]
      @suggested_edit.result = 'reject'
      @suggested_edit.reviewed_by = current_user
    elsif params[:approve]
      @suggested_edit.result = 'approve'
      @suggested_edit.reviewed_by = current_user
      rescue_request = @suggested_edit.resource
      flash[:warning] = 'Edits unable to be committed. ' unless rescue_request.update(@suggested_edit.new_values)
    end
    flash[:danger] = 'Unable to save suggested edit review.' unless @suggested_edit.save
    if SuggestedEdit.where(reviewed_by: nil).count > 0
      redirect_to action: :suggested_edit
    else
      flash[:sucess] = 'No more suggested edits to review!'
      redirect_to disaster_requests_path(disaster_id: @suggested_edit.resource.disaster_id)
    end
  end

  def review_suggested_edit_reviews
    @reviews = SuggestedEdit.all
  end

  private

  def check_admin
    require_any :developer, :admin
  end

  def check_triage
    require_any :triage, :medical, :developer, :admin
  end
end
