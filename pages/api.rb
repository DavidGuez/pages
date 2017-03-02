# encoding: utf-8

=begin
   Copyright 2016 Telegraph-ai

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
=end

require 'digest'
require 'date'

module Pages
	class Api < Sinatra::Application
		def initialize(base)
			super(base)
			@queries={
				'get_citizen_by_key'=><<END,
SELECT c.firstname,c.lastname,c.email,c.reset_code,c.registered,c.country,c.user_key,c.validation_level,c.birthday,c.telephone,c.city,ci.zipcode,ci.population,ci.departement,ci.num_circonscription,ci.num_commune,ci.code_departement, t.national as telephone_national
FROM users AS c 
LEFT JOIN cities AS ci ON (ci.city_id=c.city_id)
LEFT JOIN telephones AS t ON (t.international=c.telephone)
WHERE c.user_key=$1
END
				'get_election_by_slug'=><<END,
SELECT * from elections as ev
LEFT JOIN circonscriptions AS c ON (c.id=ev.circonscription_id)
WHERE ev.slug=$1
END
				'update_citizen_hash'=><<END,
UPDATE users SET hash=$1 WHERE email=$2 RETURNING *;
END
				'set_circonscription_by_email'=><<END,
INSERT INTO voters (election_id,email) SELECT e.election_id,$1 FROM elections as e WHERE e.slug=$2 RETURNING *
END
				'get_candidates_supported'=><<END,
SELECT c.*
FROM users AS u
INNER JOIN voters AS v ON (v.email=u.email AND u.email=$1)
INNER JOIN elections AS e ON (e.election_id=v.election_id AND e.slug=$2)
INNER JOIN supporters AS s ON (s.supporter=u.email)
INNER JOIN users AS c ON (s.candidate=c.email)
END
				'add_supporter'=><<END,
INSERT INTO supporters (election_id,supporter,candidate)
SELECT e.election_id,$1,c.email
FROM users AS c 
INNER JOIN candidates_elections AS ce ON (c.email=ce.email)
INNER JOIN elections AS e ON (e.election_id=ce.election_id AND e.slug=$3)
WHERE c.slug=$2
RETURNING *
END
				'del_supporter'=><<END,
DELETE FROM supporters AS s 
USING users as c,elections as e
WHERE c.slug=$2 AND c.email=s.candidate AND s.supporter=$1 AND e.slug=$3 AND e.election_id=s.election_id
RETURNING *
END
				'get_candidates_by_election'=><<END,
SELECT c.firstname||' '||c.lastname as name, e.slug as election_slug, c.*,s.*,ci.*,ce.* FROM users AS c
INNER JOIN candidates_elections AS ce ON (ce.email=c.email)
INNER JOIN elections AS e ON (e.election_id=ce.election_id AND e.slug=$1)
INNER JOIN circonscriptions AS ci ON (ci.id=e.circonscription_id)
LEFT JOIN supporters AS s ON (s.candidate=c.email AND s.supporter=$2 AND s.election_id=e.election_id)
END
				'get_candidate_by_slug-backup'=><<END,
SELECT * FROM users AS c 
INNER JOIN candidates_elections AS ce ON (ce.election_id=$2 AND ce.email=c.email AND c.slug=$1)
END
				'get_candidate_by_slug'=><<END,
SELECT u.*, ce.*,ci.code_departement,ci.num_circonscription, CASE WHEN s.soutiens is NULL THEN 0 ELSE s.soutiens END
    FROM users as u
    INNER JOIN candidates_elections as ce ON (ce.email=u.email)
    INNER JOIN elections as e ON (ce.election_id=e.election_id AND e.election_id=$2)
    INNER JOIN circonscriptions as ci ON (ci.id=e.circonscription_id)
    LEFT JOIN (
	    SELECT candidate,election_id,count(supporter) as soutiens
	    FROM supporters
	    GROUP BY candidate,election_id
      ) as s
  on (s.candidate = u.email AND s.election_id=e.election_id)
WHERE u.slug = $1;
END
			}
		end

		helpers do
			def error_occurred(code,msg) 
				status code
				return JSON.dump({
					'title'=>msg['title'],
					'msg'=>msg['msg']
				})
			end

			def authenticate_citizen(user_key)
				res=Pages.db_query(@queries["get_citizen_by_key"],[user_key])
				return res.num_tuples.zero? ? nil : res[0]
			end

			def authenticate_election(election_slug)
				res=Pages.db_query(@queries["get_election_by_slug"],[election_slug])
				return res.num_tuples.zero? ? nil : res[0]
			end

			def get_candidates_supported(supporter_email,election_slug)
				res=Pages.db_query(@queries["get_candidates_supported"],[supporter_email,election_slug])
				return res.num_tuples.zero? ? nil : res
			end

			def set_circonscription(email,election_slug)
				res=Pages.db_query(@queries["set_circonscription_by_email"],[email,election_slug])
				return res.num_tuples.zero? ? nil : res[0]
			end

			def add_supporter(candidate_slug,supporter_email,election_slug)
				res=Pages.db_query(@queries["add_supporter"],[supporter_email,candidate_slug,election_slug])
				return res.num_tuples.zero? ? nil : res[0]
			end

			def del_supporter(candidate_slug,supporter_email,election_slug)
				res=Pages.db_query(@queries["del_supporter"],[supporter_email,candidate_slug,election_slug])
				return res.num_tuples.zero? ? nil : res[0]
			end
			
			def get_candidates_by_election(election_slug,supporter_email)
				res=Pages.db_query(@queries["get_candidates_by_election"],[election_slug,supporter_email])
				return res.num_tuples.zero? ? nil : res
			end

			def get_candidate_by_slug(candidate_slug,election_id)
				res=Pages.db_query(@queries["get_candidate_by_slug"],[candidate_slug,election_id])
				return res.num_tuples.zero? ? nil : res[0]
			end

		end

		configure do
			set :view, 'views'
			set :root, File.expand_path('../../',__FILE__)
		end

		get '/api/token/:user_key' do
			return JSON.dump({'param_missing'=>'ballot'}) if params['ballot'].nil?
			return JSON.dump({'param_missing'=>'user key'}) if params['user_key'].nil?
			return JSON.dump({'param_missing'=>'vote id'}) if params['vote_id'].nil?
			if VOTE_PAUSED then
				status 404
				return JSON.dump({'message'=>'votes are currently paused, please retry in a few minutes...'})
			end
			begin
				Pages.db_init()
				res=Pages.db_query(@queries["get_ballot_by_id"],[params['ballot'],params['user_key']])
				ballot=res[0]
				token={
					:iss=> COCORICO_APP_ID,
					:sub=> Digest::SHA256.hexdigest(ballot['email']),
					:email=> ballot['email'],
					:lastName=> ballot['lastname'],
					:firstName=> ballot['firstname'],
					:birthdate=> ballot['birthday'],
					:authorizedVotes=> [ballot['cc_vote_id']],
					:exp=>(Time.new.getutc+VOTING_TIME_ALLOWED).to_i
				}
				vote_token=JWT.encode token, COCORICO_SECRET, 'HS256'
				res=Pages.db_query(@queries["update_citizen_hash"],[token[:sub],ballot['email']])
			rescue PG::Error => e
				Pages.log.error "/citoyen/token DB Error #{params}\n#{e.message}"
				status 500
				return JSON.dump({"title"=>"Erreur serveur","message"=>e.message})
			ensure
				Pages.db_close()
			end
			return JSON.dump({'token'=>vote_token})
		end

		get '/api/citizen/:user_key/election/:election_slug/candidates' do
			begin
				Pages.db_init()
				citoyen=authenticate_citizen(params['user_key'])
				return error_occurred(404,{"title"=>"Page inconnue","msg"=>"La page demandée n'existe pas [code:ACEC0]"}) if citoyen.nil?
				return error_occurred(403,{"title"=>"Authentification manquante","msg"=>"Merci de vous authentifier [code:ACEC1]"}) if citoyen['validation_level'].to_i<3
				election=authenticate_election(params['election_slug'])
				return error_occurred(404,{"title"=>"Page inconnue","msg"=>"La page demandée n'existe pas [code:ACEC2]"}) if election.nil?
				candidates=get_candidates_by_election(params['election_slug'],citoyen['email'])
				json=[]
				if not candidates.nil? then
					candidates.each do |c| 
						c['fields']=JSON.parse(c['fields'])
						json.push(c)
					end
				end
			rescue PG::Error => e
				Pages.log.error "/api/citizen/elections/candidates DB Error [code:ACEC4] #{params}\n#{e.message}"
				return error_occurred(500,{"title"=>"Erreur serveur","msg"=>"Récupération des infos impossible [code:ACEC4]"})
			ensure
				Pages.db_close()
			end
			return JSON.dump({'candidates'=>json});
		end

		post '/api/citizen/:user_key/election/:election_slug/support/:candidate_slug' do
			begin
				Pages.db_init()
				citoyen=authenticate_citizen(params['user_key'])
				return error_occurred(404,{"title"=>"Erreur","msg"=>"Utilisateur inconnu"}) if citoyen.nil?
				candidates=get_candidates_supported(citoyen['email'],params[:election_slug])
				return error_occurred(500,{"title"=>"Info","msg"=>"Nombre maximum de soutiens atteint"}) if (not candidates.nil? and candidates.num_tuples==3)
				res=add_supporter(params['candidate_slug'],citoyen['email'],params[:election_slug])
				return error_occurred(500,{"title"=>"Erreur","msg"=>"Soutien non pris en compte"}) if res.nil?
			rescue PG::Error => e
				Pages.log.error "/api/citizen/candidate/support DB Error [code:ACES] #{params}\n#{e.message}"
				return error_occurred(500,{"title"=>"Erreur","msg"=>"Une erreur est survenue [code:ACES]"})
			ensure
				Pages.db_close()
			end
			return JSON.dump({'success'=>1})
		end

		post '/api/citizen/:user_key/election/:election_slug/unsupport/:candidate_slug' do
			begin
				Pages.db_init()
				citoyen=authenticate_citizen(params['user_key'])
				return error_occurred(404,{"title"=>"Erreur","msg"=>"Utilisateur inconnu"}) if citoyen.nil?
				res=del_supporter(params['candidate_slug'],citoyen['email'],params['election_slug'])
				return error_occurred(500,{"title"=>"Erreur","msg"=>"Soutien non supprimé"}) if res.nil?
			rescue PG::Error => e
				Pages.log.error "/api/citizen/candidate/unsupport DB Error [code:ACEU] #{params}\n#{e.message}"
				return error_occurred(500,{"title"=>"Erreur","msg"=>"Une erreur est survenue [code:ACEU]"})
			ensure
				Pages.db_close()
			end
			return JSON.dump({'success'=>1})
		end

		post '/api/citizen/:user_key/election/:election_slug/inscription' do
			begin
				Pages.db_init()
				citoyen=authenticate_citizen(params['user_key'])
				return error_occurred(404,{"title"=>"Erreur","msg"=>"Utilisateur inconnu"}) if citoyen.nil?
				election=authenticate_election(params['election_slug'])
				return error_occurred(404,{"title"=>"Page inconnue","msg"=>"La page demandée n'existe pas [code:ACEI0]"}) if election.nil?
				circonscription=set_circonscription(citoyen['email'],params['election_slug'])
				return error_occurred(500,{"title"=>"Erreur","msg"=>"Circonscription non définie [code:ACEI1]"}) if circonscription.nil?
			rescue PG::Error => e
				Pages.log.error "/api/citizen/election/inscription DB Error [code:ACEI2] #{params}\n#{e.message}"
				return error_occurred(500,{"title"=>"Erreur","msg"=>"Une erreur est survenue [code:ACEI2]"})
			ensure
				Pages.db_close()
			end
			return JSON.dump({'success'=>1})
		end

		get '/api/election/:election_slug/candidate/:candidate_slug/summary' do
			begin
				Pages.db_init()
				election=authenticate_election(params['election_slug'])
				return error_occurred(404,{"title"=>"Page inconnue","msg"=>"La page demandée n'existe pas [code:AECS0]"}) if election.nil?
				candidate=get_candidate_by_slug(params['candidate_slug'],election['election_id'])
				return error_occurred(404,{"title"=>"Erreur","msg"=>"Candidat inconnu"}) if candidate.nil?
				candidate_fields=JSON.parse(candidate['fields'])
				candidate.merge!(candidate_fields)
				candidate.delete('fields')
				birthday=Date.parse(candidate['birthday'].split('?')[0]) unless candidate['birthday'].nil?
				age=nil
				unless birthday.nil? then
					now = Time.now.utc.to_date
					candidate['age'] = now.year - birthday.year - ((now.month > birthday.month || (now.month == birthday.month && now.day >= birthday.day)) ? 0 : 1)
				end

			rescue PG::Error => e
				Pages.log.error "/api/election/candidate/summary DB Error [code:AECS1] #{params}\n#{e.message}"
				return error_occurred(500,{"title"=>"Erreur","msg"=>"Une erreur est survenue [code:AECS1]"})
			ensure
				Pages.db_close()
			end
			return JSON.dump(candidate);
		end
	end
end