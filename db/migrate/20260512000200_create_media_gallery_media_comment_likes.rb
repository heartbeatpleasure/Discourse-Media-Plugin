# frozen_string_literal: true

class CreateMediaGalleryMediaCommentLikes < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:media_gallery_media_comment_likes)
      create_table :media_gallery_media_comment_likes do |t|
        t.integer :media_item_id, null: false
        t.integer :media_comment_id, null: false
        t.integer :user_id, null: false
        t.timestamps null: false
      end
    end

    add_index_unless_exists :media_gallery_media_comment_likes,
                            [:media_comment_id, :user_id],
                            unique: true,
                            name: "idx_media_gallery_comment_likes_comment_user"
    add_index_unless_exists :media_gallery_media_comment_likes,
                            [:media_comment_id, :id],
                            name: "idx_media_gallery_comment_likes_comment_id"
    add_index_unless_exists :media_gallery_media_comment_likes,
                            [:media_item_id, :user_id],
                            name: "idx_media_gallery_comment_likes_item_user"
    add_index_unless_exists :media_gallery_media_comment_likes,
                            [:user_id, :created_at],
                            name: "idx_media_gallery_comment_likes_user_created"

    unless column_exists?(:media_gallery_media_comments, :likes_count)
      add_column :media_gallery_media_comments, :likes_count, :integer, null: false, default: 0
    end
  end

  def down
    remove_column :media_gallery_media_comments, :likes_count if column_exists?(:media_gallery_media_comments, :likes_count)
    drop_table :media_gallery_media_comment_likes if table_exists?(:media_gallery_media_comment_likes)
  end

  private

  def add_index_unless_exists(table, columns, **options)
    return if index_exists?(table, columns, name: options[:name])

    add_index table, columns, **options
  end
end
