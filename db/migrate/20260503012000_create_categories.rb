class CreateCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :categories, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.citext :name, null: false
      t.timestamps
    end

    add_index :categories, :name, unique: true
  end
end
