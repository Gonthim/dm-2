class GenerateThumbnailWorker
  include Sidekiq::Worker

  def perform(document_id, tile_source)
    doc = Document.find(document_id)
    return if doc.thumbnail.attached?
    tile_source.sub!('/info.json', '')
    thumb_url = tile_source + '/full/160,160/0/default.jpg'
    doc.add_thumbnail(thumb_url)
  rescue => exception
    Rails.logger.error "Unable to generate thumb: #{exception}"
  end
end
