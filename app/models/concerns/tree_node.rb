module TreeNode
    extend ActiveSupport::Concern

    def add_to_tree
        self.move_to( 0 )
    end

    def remove_from_tree
        children = self.parent.contents_children
        ActiveRecord::Base.transaction do    
            i = 0
            children.each { |child|
                unless child.destroyed?
                    unless same_as( self, child )
                        child.position = i 
                        i = i + 1
                    else
                        child.parent = nil
                    end                    
                    child.save!
                end
            }
        end    
    end

    def add_subtree( tree )
        project_id = self.document_kind == 'Project' ?  self.id : self.project_id
        parent_type = self.document_kind == 'Project' ? 'Project' : 'DocumentFolder'
        inserted_docs = []
        ActiveRecord::Base.transaction do
            # build subtree recursively, extract list of documents to insert
            root_folder, documents = add_child_folders(project_id, self.id, parent_type, tree)

            # batch insert documents
            if documents.any?
                result = Document.insert_all!(documents, returning: %w[id content])
                # prepare docs for thumbnail generation
                inserted_docs = result.rows.map do |id, content_json|
                    content = JSON.parse(content_json)
                    [id, content['tileSources'].first]
                end
            end

            # batch renumber
            root_folder.renumber_children
        end
        # use worker job to offload thumbnail generation after docs created
        inserted_docs.each do |id, thumb_url|
            GenerateThumbnailWorker.perform_async(id, thumb_url)
        end
    end

    def add_child_folders(project_id, parent_id, parent_type, node)
        folder = DocumentFolder.create!(
            project_id: project_id,
            title: node['name'],
            parent_id: parent_id,
            parent_type: parent_type
        )

        child_documents = []

        (node['children'] || []).each do |child|
            if child['children']
                subfolder, subdocs = add_child_folders(project_id, folder.id, 'DocumentFolder', child)
                child_documents.concat(subdocs)
            else
                child_documents << {
                    project_id: project_id,
                    parent_id: folder.id,
                    parent_type: 'DocumentFolder',
                    title: child['name'],
                    document_kind: 'canvas',
                    content: { tileSources: [child['image_info_uri']] },
                    created_at: Time.current,
                    updated_at: Time.current
                }
            end
        end

        [folder, child_documents]
    end

    def contents_children
        (self.documents + self.document_folders).sort_by(&:position)
    end

    def renumber_children( children=nil )
        # renumber all children from 0 using existing order, in a single query
        children ||= contents_children
        updated_children = children.each_with_index.map do |child, i|
            {
                # keep track of class for Document vs DocumentFolder
                klass: child.class,
                attrs: child.attributes.merge(
                    # update position and timestamps; keep other attrs
                    "position" => i,
                    "updated_at" => Time.current,
                    "created_at" => child.created_at || Time.current
                )
            }
        end
        updated_children.group_by { |h| h[:klass] }.each do |klass, group|
            # perform upsert_all per class (Document vs DocumentFolder)
            klass.upsert_all(group.map { |h| h[:attrs] }, unique_by: [:id])
        end
    end

    def list_positions
        self.contents_children.map { |child| [child.id, child.position] }
    end

    def same_as(node_a, node_b)
        return true if node_a.nil? && node_b.nil?
        return false if node_a.nil? || node_b.nil?        
        node_a.id == node_b.id && node_a.class.to_s == node_b.class.to_s 
    end

    def get_tree_node_record( record_id, record_type )
        if record_type == "Project" 
            return Project.find(record_id)
        elsif record_type == "DocumentFolder"
            return DocumentFolder.find(record_id)
        elsif record_type == "Document"
            return Document.find(record_id)
        end
    end

    def move_to( target_position, destination_id=nil, destination_type='DocumentFolder' )
        destination = destination_id.nil? ? 
            self.get_tree_node_record(self.parent_id, self.parent_type) : 
            self.get_tree_node_record(destination_id, destination_type)      

        if same_as(self.parent, destination)
            siblings = (destination.documents + destination.document_folders ).sort_by(&:position)
        else
            old_parent = self.parent
            self.parent = destination
            siblings = (destination.documents + destination.document_folders + [self]).sort_by(&:position)
        end

        skip_renumbering = (target_position == :end && old_parent.nil?)
        target_position = siblings.length + 1 if target_position == :end

        # start_state = siblings.map { |child| [child.id, child.position] }
        # logger.info "MOVING #{destination_id} to #{target_position}"
        # logger.info "START STATE: #{start_state}"

        # move to right spot, note this is only saved when transaction suceeds
        siblings.each { |sibling|
            if same_as(sibling,self) 
                sibling.position = target_position
            else
                if sibling.position >= target_position
                    sibling.position = sibling.position + 1
                end
            end
        }

        # end_state = siblings.map { |child| [child.id, child.position] }
        # logger.info "END STATE: #{end_state}"

        unless skip_renumbering
            # resort them again
            siblings = siblings.sort_by(&:position)

            # renumber the leafs
            renumber_children(siblings)
            old_parent.renumber_children() unless old_parent.nil?
        else
            # being inserted 
            self.save!
        end
        
        # end_state = siblings.map { |child| [child.id, child.position] }
        # logger.info "RENUMBERED STATE: #{end_state}"
    end   
end