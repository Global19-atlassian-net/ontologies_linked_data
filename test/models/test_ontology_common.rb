require_relative "../test_case"

module LinkedData
  class TestOntologyCommon < LinkedData::TestCase
    def submission_dependent_objects(format, acronym, user_name, name_ont)
      #ontology format
      owl = LinkedData::Models::OntologyFormat.where(:acronym => format).first
      assert_instance_of LinkedData::Models::OntologyFormat, owl

      #user test_linked_models
      user = LinkedData::Models::User.where(:username => user_name).first
      if user.nil?
        user = LinkedData::Models::User.new(:username => user_name, :email => "some@email.org" )
        user.passwordHash = "some random pass hash"
        user.save
      end
      #
      #ontology
      ont = LinkedData::Models::Ontology.where(:acronym => acronym).first
      if ont.nil?
        ont = LinkedData::Models::Ontology.new(:acronym => acronym, :name => name_ont, administeredBy: [user]).save
      end

      # contact
      contact_name = "Peter"
      contact_email = "peter@example.org"
      contact = LinkedData::Models::Contact.where(name: contact_name, email: contact_email).first
      contact = LinkedData::Models::Contact.new(name: contact_name, email: contact_email).save if contact.nil?

      #Submission Status
      return owl, ont, user, contact
    end

    ##############################################
    # Possible parse_options with their defaults:
    #   index_search      = true
    #   run_metrics       = true
    #   reasoning         = true
    ##############################################
    def submission_parse( acronym, name, ontologyFile, id, parse_options={})
      return if ENV["SKIP_PARSING"]
      parse_options[:process_rdf] = true

      bro = LinkedData::Models::Ontology.find(acronym).first
      if not bro.nil?
        bro.bring(:submissions)
        sub = bro.submissions || []
        sub.each do |s|
          s.delete
        end
      end
      ont_submision =  LinkedData::Models::OntologySubmission.new({ :submissionId => id})
      assert (not ont_submision.valid?)
      assert_equal 4, ont_submision.errors.length
      uploadFilePath = LinkedData::Models::OntologySubmission.copy_file_repository(acronym, id, ontologyFile)
      ont_submision.uploadFilePath = uploadFilePath
      ontology_type = "OWL"
      if (ontologyFile && ontologyFile.end_with?("obo"))
        ontology_type = "OBO"
      end
      owl, bro, user, contact = submission_dependent_objects(ontology_type, acronym, "test_linked_models", name)
      ont_submision.contact = [contact]
      ont_submision.released = DateTime.now - 4
      ont_submision.hasOntologyLanguage = owl
      ont_submision.ontology = bro
      masterFileName = parse_options.delete :masterFileName
      if masterFileName
        ont_submision.masterFileName = masterFileName
      end
      assert (ont_submision.valid?)
      ont_submision.save

      assert_equal true, ont_submision.exist?(reload=true)
      ont_submision.process_submission(Logger.new(STDOUT), parse_options)
    end

    def init_test_ontology_msotest(acr)
      ont = LinkedData::Models::Ontology.find(acr)
                .include(submissions: [:submissionStatus]).first
      if not ont.nil?
        sub = ont.submissions || []
        if sub.length > 0
          return if sub[0].ready?
        end
        sub.each do |s|
          s.delete
        end
        ont.delete
      end
      ont_submision =  LinkedData::Models::OntologySubmission.new({ :submissionId => 1 })
      assert (not ont_submision.valid?)
      assert_equal 4, ont_submision.errors.length
      if acr["OBS"]
        file_path = "./test/data/ontology_files/custom_obsolete.owl"
      else
        file_path = "./test/data/ontology_files/custom_properties.owl"
      end

      uploadFilePath = LinkedData::Models::OntologySubmission.copy_file_repository(acr, 1, file_path)
      ont_submision.uploadFilePath = uploadFilePath
      owl, ont, user, contact = submission_dependent_objects("OWL", acr, "test_linked_models", "some ont created by mso for testing")
      ont.administeredBy = [user]
      ont_submision.contact = [contact]
      ont_submision.released = DateTime.now - 4
      ont_submision.hasOntologyLanguage = owl
      ont_submision.ontology = ont
      if acr["OBS"]
        if acr["BRANCH"]
          ont_submision.obsoleteParent = 
            RDF::URI.new("http://bioportal.bioontology.org/ontologies/msotes#class1")
        else
          ont_submision.obsoleteProperty = 
            RDF::URI.new("http://bioportal.bioontology.org/ontologies/msotes#mydeprecated")
        end
      end
      ont_submision.prefLabelProperty = RDF::URI.new("http://bioportal.bioontology.org/ontologies/msotes#myPrefLabel")
      ont_submision.synonymProperty = RDF::URI.new("http://bioportal.bioontology.org/ontologies/msotes#mySynonymLabel")
      ont_submision.definitionProperty = RDF::URI.new("http://bioportal.bioontology.org/ontologies/msotes#myDefinition")
      ont_submision.authorProperty = RDF::URI.new("http://bioportal.bioontology.org/ontologies/msotes#myAuthor")
      assert (ont_submision.valid?)
      ont_submision.save
      assert_equal true, ont_submision.exist?(reload=true)
      ont_submision.process_submission(Logger.new(STDOUT),
                                       process_rdf: true, index_search: true,
                                       run_metrics: true, reasoning: true)
      roots = ont_submision.roots
      #class99 is equilent to intersection of ...
      #it shouldnt be at the root
      if acr["OBSPROPS"]
        assert roots.length == 4
      elsif acr["OBSBRANCH"]
        assert roots.length == 5
      else
        assert roots.length == 6
      end
      assert !roots.map { |x| x.id.to_s }
              .include?("http://bioportal.bioontology.org/ontologies/msotes#class99")

      #test to see if custom properties were saved in the graph
      custom_props = [ "http://bioportal.bioontology.org/ontologies/msotes#myPrefLabel",
        "http://bioportal.bioontology.org/ontologies/msotes#myDefinition",
        "http://bioportal.bioontology.org/ontologies/msotes#mySynonymLabel",
        "http://bioportal.bioontology.org/ontologies/msotes#myAuthor"]
      custom_props.each do |p|
        query = <<eos
SELECT * WHERE {
    GRAPH #{ont_submision.id.to_ntriples} {
        <#{p}> <http://www.w3.org/2000/01/rdf-schema#subPropertyOf> ?super .
    } }
eos
        count = 0
        Goo.sparql_query_client.query(query).each_solution do |sol|
          if (sol[:super].to_s.include? "skos") || (sol[:super].to_s.include? "elements") ||  (sol[:super].to_s.include? "metadata")
            count += 1
          end
        end
        assert (count > 0)
      end
    end
  end
end

