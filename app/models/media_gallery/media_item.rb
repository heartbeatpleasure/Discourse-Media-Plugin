# frozen_string_literal: true

module ::MediaGallery
  class MediaItem < ::ActiveRecord::Base
    self.table_name = "media_gallery_media_items"

    belongs_to :user
    belongs_to :original_upload, class_name: "::Upload", optional: true
    belongs_to :processed_upload, class_name: "::Upload", optional: true
    belongs_to :thumbnail_upload, class_name: "::Upload", optional: true

    has_many :media_likes, class_name: "MediaGallery::MediaLike", dependent: :delete_all

    STATUSES = %w[queued processing ready failed].freeze
    TYPES = %w[video audio image].freeze
    GENDERS = %w[male female non_binary].freeze

    validates :public_id, presence: true, uniqueness: true
    validates :status, inclusion: { in: STATUSES }
    validates :media_type, inclusion: { in: TYPES }, allow_nil: true
    validates :gender, inclusion: { in: GENDERS }, allow_nil: true
    validates :title, presence: true, length: { maximum: 200 }
    validates :description, length: { maximum: 4000 }, allow_nil: true
    validate :tags_are_reasonable

    before_validation :ensure_public_id, on: :create
    before_validation :normalize_tags

    def ensure_public_id
      self.public_id ||= SecureRandom.uuid
    end

    def normalize_tags
      self.tags ||= []
      self.tags = self.tags.map { |t| t.to_s.strip.downcase }.reject(&:blank?).uniq
    end

    def tags_are_reasonable
      max = SiteSetting.media_gallery_max_tags_per_item.to_i
      if tags.length > max
        errors.add(:tags, "too many tags (max #{max})")
        return
      end

      allowed = MediaGallery::Permissions.allowed_tags
      return if allowed.blank?

      invalid = tags - allowed.map { |t| t.to_s.strip.downcase }
      errors.add(:tags, "contains invalid tags") if invalid.any?
    end

    def ready?
      status == "ready"
    end

    def queued_or_processing?
      status == "queued" || status == "processing"
    end
  end
end
