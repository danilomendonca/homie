class AddBrandAndNotesToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :brand, :citext
    add_column :products, :notes, :text
  end
end
