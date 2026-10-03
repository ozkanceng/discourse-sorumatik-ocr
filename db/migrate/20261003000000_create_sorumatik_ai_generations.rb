# frozen_string_literal: true

class CreateSorumatikAiGenerations < ActiveRecord::Migration[7.0]
  def change
    create_table :sorumatik_ai_generations do |t|
      t.string :generation_id, null: false
      t.bigint :topic_id, null: false
      t.bigint :source_post_id, null: false
      t.bigint :user_id, null: false
      t.bigint :post_id
      t.string :state, null: false, default: "queued"
      t.integer :sequence, null: false, default: 0
      t.text :raw, null: false, default: ""
      t.jsonb :metrics, null: false, default: {}
      t.jsonb :error
      t.integer :save_attempts, null: false, default: 0
      t.timestamps
    end
    add_index :sorumatik_ai_generations, :generation_id, unique: true
    add_index :sorumatik_ai_generations, :source_post_id, unique: true
    add_index :sorumatik_ai_generations, [:state, :updated_at]
    add_index :sorumatik_ai_generations, [:topic_id, :user_id, :created_at], name: "idx_sorumatik_generations_topic_user"
  end
end
