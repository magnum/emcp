# frozen_string_literal: true

# This migration comes from acts_as_taggable_on_engine (originally 5)
class ChangeCollationForTagNames < ActiveRecord::Migration[8.1]
  def up
    if ActsAsTaggableOn::Utils.using_mysql?
      execute("ALTER TABLE #{ActsAsTaggableOn.tags_table} MODIFY name varchar(255) CHARACTER SET utf8 COLLATE utf8_bin;")
    end
  end
end
