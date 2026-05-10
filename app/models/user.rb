class User < ApplicationRecord
  devise :database_authenticatable, :recoverable, :rememberable, :validatable

  validates :name, presence: true
  validates :organisation, presence: true
end
