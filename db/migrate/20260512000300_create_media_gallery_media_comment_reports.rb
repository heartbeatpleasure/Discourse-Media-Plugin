# frozen_string_literal: true

class CreateMediaGalleryMediaCommentReports < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:media_gallery_media_comment_reports)
      create_table :media_gallery_media_comment_reports do |t|
        t.integer :media_item_id, null: false
        t.integer :media_comment_id, null: false
        t.integer :comment_user_id
        t.integer :user_id, null: false
        t.string :reason, null: false
        t.text :message
        t.string :status, null: false, default: "open"
        t.datetime :reviewed_at
        t.integer :reviewed_by_id
        t.text :review_note
        t.jsonb :snapshot, null: false, default: {}
        t.timestamps null: false
      end
    end

    add_index_unless_exists :media_gallery_media_comment_reports,
                            [:media_comment_id, :user_id, :status],
                            name: "idx_media_gallery_comment_reports_comment_user_status"
    add_index_unless_exists :media_gallery_media_comment_reports,
                            [:media_comment_id, :status, :created_at],
                            name: "idx_media_gallery_comment_reports_comment_status_created"
    add_index_unless_exists :media_gallery_media_comment_reports,
                            [:media_item_id, :status, :created_at],
                            name: "idx_media_gallery_comment_reports_item_status_created"
    add_index_unless_exists :media_gallery_media_comment_reports,
                            [:user_id, :created_at],
                            name: "idx_media_gallery_comment_reports_user_created"
    add_index_unless_exists :media_gallery_media_comment_reports,
                            [:comment_user_id, :created_at],
                            name: "idx_media_gallery_comment_reports_comment_user_created"

    unless column_exists?(:media_gallery_media_comments, :reports_count)
      add_column :media_gallery_media_comments, :reports_count, :integer, null: false, default: 0
    end
  end

  def down
    remove_column :media_gallery_media_comments, :reports_count if column_exists?(:media_gallery_media_comments, :reports_count)
    drop_table :media_gallery_media_comment_reports if table_exists?(:media_gallery_media_comment_reports)
  end

  private

  def add_index_unless_exists(table, columns, **options)
    return if index_exists?(table, columns, name: options[:name])

    add_index table, columns, **options
  end
end
