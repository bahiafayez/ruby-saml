# The contents of this file are subject to the terms
# of the Common Development and Distribution License
# (the License). You may not use this file except in
# compliance with the License.
#
# You can obtain a copy of the License at
# https://opensso.dev.java.net/public/CDDLv1.0.html or
# opensso/legal/CDDLv1.0.txt
# See the License for the specific language governing
# permission and limitations under the License.
#
# When distributing Covered Code, include this CDDL
# Header Notice in each file and include the License file
# at opensso/legal/CDDLv1.0.txt.
# If applicable, add the following below the CDDL Header,
# with the fields enclosed by brackets [] replaced by
# your own identifying information:
# "Portions Copyrighted [year] [name of copyright owner]"
#
# $Id: xml_sec.rb,v 1.6 2007/10/24 00:28:41 todddd Exp $
#
# Copyright 2007 Sun Microsystems Inc. All Rights Reserved
# Portions Copyrighted 2007 Todd W Saxton.

require 'rubygems'
require "rexml/document"
require "rexml/xpath"
require "openssl"
require "xmlcanonicalizer"
require "digest/sha1"
require "onelogin/saml/validation_error"

module XMLSecurity
  
  class SignedDocument < REXML::Document
	  include Onelogin::Saml
    DSIG = "http://www.w3.org/2000/09/xmldsig#"

    attr_accessor :signed_element_id

    def initialize(response)
      super(response)
      extract_signed_element_id
    end

    def validate(settings, soft = true, connect_to)
		@settings = settings
		x509_cert = REXML::XPath.first(self, "//ds:X509Certificate")
		# What to do if the document doesn't have an X509 cert?  
		# I'm not sure if the SAML specs require a cert with signed docs,
		# or if the absense of a cert means this document is not signed.
		# In this case, return true because we can't perform a signature check
		unless x509_cert 
			return true
		end
		
		base64_cert = x509_cert.text.gsub(/\n/, "")
		puts "base64_cert in xml_security is #{base64_cert}"
		
		# If we're using idp metadata, grab necessary info from it 
		if @settings.idp_metadata != nil
			metadata = Onelogin::Saml::Metadata.new(@settings, connect_to)
			meta_doc = metadata.get_idp_metadata
    
    puts "metadata cert is #{@settings.idp_cert}"

			# compare the certificate in response with the IdP's copy
			if @settings.idp_cert.strip != base64_cert.strip
			  puts "They are not equal"
				return soft ? false : (raise Onelogin::Saml::ValidationError.new("Response certificate does not match the IdP's certificate in metadata"))
			end
		# If we're using the old fingerprint method 
		elsif @settings.idp_cert_fingerprint != nil
			# get cert from response
			cert_text   = Base64.decode64(base64_cert)
			cert        = OpenSSL::X509::Certificate.new(cert_text)

			# check cert matches registered idp cert
			fingerprint = Digest::SHA1.hexdigest(cert.to_der)

			if fingerprint != @settings.idp_cert_fingerprint.gsub(/[^a-zA-Z0-9]/,"").downcase
			return soft ? false : (raise Onelogin::Saml::ValidationError.new("Fingerprint mismatch"))
			end
		end
		
      validate_doc(base64_cert, soft)
    end

    def validate_doc(base64_cert, soft = true)
      # validate references
      
      # check for inclusive namespaces
      
      inclusive_namespaces            = []
      inclusive_namespace_element     = REXML::XPath.first(self, "//ec:InclusiveNamespaces")
      
      if inclusive_namespace_element
        prefix_list                   = inclusive_namespace_element.attributes.get_attribute('PrefixList').value
        inclusive_namespaces          = prefix_list.split(" ")
      end

      # remove signature node
      sig_element = REXML::XPath.first(self, "//ds:Signature", {"ds"=>"http://www.w3.org/2000/09/xmldsig#"})
      sig_element.remove

      # check digests
      REXML::XPath.each(sig_element, "//ds:Reference", {"ds"=>"http://www.w3.org/2000/09/xmldsig#"}) do |ref|
        uri                           = ref.attributes.get_attribute("URI").value
        hashed_element                = REXML::XPath.first(self, "//[@ID='#{uri[1,uri.size]}']")
        canoner                       = XML::Util::XmlCanonicalizer.new(false, true)
        canoner.inclusive_namespaces  = inclusive_namespaces if canoner.respond_to?(:inclusive_namespaces) && !inclusive_namespaces.empty?
        canon_hashed_element          = canoner.canonicalize(hashed_element).gsub('&', '&amp;')
        hash                          = Base64.encode64(Digest::SHA1.digest(canon_hashed_element)).chomp
        digest_value                  = REXML::XPath.first(ref, "//ds:DigestValue", {"ds"=>"http://www.w3.org/2000/09/xmldsig#"}).text
			
			  puts "Hash iss #{hash}"
        puts "digest value is #{digest_value}"
        			
        unless digests_match?(hash, digest_value)
          return soft ? false : (raise Onelogin::Saml::ValidationError.new("Digest mismatch"))
        end
      end

      # verify signature
      canoner                 = XML::Util::XmlCanonicalizer.new(false, true)
      signed_info_element     = REXML::XPath.first(sig_element, "//ds:SignedInfo", {"ds"=>"http://www.w3.org/2000/09/xmldsig#"})
      canon_string            = canoner.canonicalize(signed_info_element)
      puts "canon_string is #{canon_string}"

      base64_signature        = REXML::XPath.first(sig_element, "//ds:SignatureValue", {"ds"=>"http://www.w3.org/2000/09/xmldsig#"}).text
      signature               = Base64.decode64(base64_signature)
      puts "signature is #{signature}"
      
      # get certificate object
      cert_text               = Base64.decode64(base64_cert)
      cert                    = OpenSSL::X509::Certificate.new(cert_text)
      puts "cert is #{cert}"
      
      if !cert.public_key.verify(OpenSSL::Digest::SHA1.new, signature, canon_string)
        puts "key validation error"
        return soft ? false : (raise ValidationError.new("Key validation error"))
      end

      return true
    end

    private
	 
	 def digests_match?(hash, digest_value)
      hash == digest_value
	 end
	 
    def extract_signed_element_id
      reference_element       = REXML::XPath.first(self, "//ds:Signature/ds:SignedInfo/ds:Reference", {"ds"=>DSIG})
      self.signed_element_id  = reference_element.attribute("URI").value unless reference_element.nil?
    end
  end
end
