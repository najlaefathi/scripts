#!/bin/bash

# fonctionnement:
# il récupere les hosts depuis Ganglia en s'aidant du script /usr/share/ganglia-webfrontend/nagios/get_hosts.php se trouvant sur la machine Gmetad
# il récupere les hosts depuis l'API Centreon aprés l'authentification et  l'obtention d'un jeton
# test si les hosts de Ganglia existe déja sur Centron:
#	si ce n'est pas le cas, il ajoute les hosts a Centreon

# cette fonctionsera utilisé à la fin
function list_include_item {
  local list="$1"
  local item="$2"
  if [[ $list =~ (^|[[:space:]])"$item"($|[[:space:]]) ]] ; then
    # yes, list include item
    result=0
  else
    result=1
  fi
  return $result
}

# host_type : dockerhost / api
host_type=$1

if [ "$host_type" == "api" ];then
    filter="?hreg=^api\."
else
    filter="?hreg=^(core\d*|coredb\d*|geoserver\d*|modelrunner\d*)\."
fi

GANGLIA_URL="https://ganglia.forcity.io/ganglia/nagios/get_hosts.php"

# retrieve hosts from ganglia
# -s pour mode silence
HOSTS=$(curl -s "${GANGLIA_URL}${filter}")
echo $HOSTS
# authenticate against Centreon (needs user test_user/test_password with Reach API rights)
# -s : silence
# -XPOST : X pour pouvoir utiliser le mode POST
# --data pour remplire le post
# | : pipe, la sortie de la 1ere commande devient l'entree de la 2eme commande
# jq -r pour transformer le resultat json en string: ".authToken" pour avoir la valeur de la clé authToken
token=$(curl -s -XPOST 'http://127.0.0.1/centreon/api/index.php?action=authenticate' --data "username=test_user&password=test_password" |jq -r ".authToken")
# echo "token=$token"
# retrieve existing hosts from Centreon
# voir doc: https://documentation.centreon.com/docs/centreon/en/2.8.x/api/api_rest/index.html#list-hosts
# besoin de:
# Body : --data '{"action": "show","object": "host"}'
# Header: -H "Content-Type:application/json" -H "centreon_auth_token:$token" ,centreon_auth_token appel la variable $token qui contient la clé d'auth
# |jq -r ".result[].name" :  transforme du jsson en string et prend le la valeur de la clé name ( des hosts)
KNOWNHOSTS=$(curl -s -XPOST 'http://127.0.0.1/centreon/api/index.php?action=action&object=centreon_clapi' \
 --data '{
  "action": "show",
  "object": "host"
}' \
 -H "Content-Type:application/json" \
 -H "centreon_auth_token:$token" |jq -r ".result[].name")

echo $KNOWNHOSTS
# echo curl -s -XPOST 'http://127.0.0.1/centreon/api/index.php?action=action&object=centreon_clapi' --data '{"action": "show","object": "host"}' -H "Content-Type:application/json" -H "centreon_auth_token:$token"

# compare entre les hosts de ganglia et les hosts de centreon, si un host ganglia n'existe pas dans centreon, il sera ajouté
# list_include_item() : fonction qui compare et retourne 0 si host existe et 1 sinon
# || : it will evaluate the right side only if the left side exit status is nonzero, c-a-d qu'on ajoute le host dans centreon si list_include_item() retourne 1
# voir doc : https://documentation.centreon.com/docs/centreon/en/2.8.x/api/api_rest/index.html#add-host
# necessite:
# Body : --data
# Header : -H:
# 	1 : host name
#	2 : alias
#	3 : ip
#	4 : host template (doit etre déja ajouté a centreon), ici c'est ganglia-host
#	5 : poller
#	6 : host group (doit etre déja ajouté a centreon), ici c'est docker-hosts
# for each host in ganglia
need_restart=
for host in $HOSTS; do
  if [[ $host = *[!\ ]* ]]; then #test si $host est vide
    if [ "$host_type" == "api" ];then
        api_host=$(echo $host|sed -r 's/^.+?\.(.+\.forcity\.io)$/\1/')
        geoserver_host=$(echo $api_host |sed -r 's/\.forcity\.io/-geoserver.forcity.io/')
        # check if hosts already exist in centreon hosts list; if not, add host to centreon (needs work on values field; needs ganglia-host template, and docker-hosts host group)
        if [ ! $(list_include_item "$KNOWNHOSTS" "$api_host") ]; then
          curl -s -XPOST 'http://127.0.0.1/centreon/api/index.php?action=action&object=centreon_clapi' \
              --data "{
                \"action\": \"add\",
                \"object\": \"host\",
                \"values\": \"$api_host;$api_host;$api_host;api-host;central;api-hosts\"
              }" \
              -H "Content-Type:application/json" \
              -H "centreon_auth_token:$token"

          ip=$(dig +short $geoserver_host |tr -d ' ')
          if [ "$ip" == "" ]; then
              geoserver_host=$api_host
              curl -s -XPOST 'http://127.0.0.1/centreon/api/index.php?action=action&object=centreon_clapi' \
               --data "{
                 \"action\": \"addhostgroup\",
                 \"object\": \"host\",
                 \"values\": \"$geoserver_host;geoserver-hosts\"
               }" \
               -H "Content-Type:application/json" \
               -H "centreon_auth_token:$token"
          else
            if [ ! $(list_include_item "$KNOWNHOSTS" "$geoserver_host") ]; then
              curl -s -XPOST 'http://127.0.0.1/centreon/api/index.php?action=action&object=centreon_clapi' \
               --data "{
                 \"action\": \"add\",
                 \"object\": \"host\",
                 \"values\": \"$geoserver_host;$geoserver_host;$geoserver_host;api-host;central;geoserver-hosts\"
               }" \
               -H "Content-Type:application/json" \
               -H "centreon_auth_token:$token"
            fi
          fi
        fi
        need_restart=1
    else
      # check if hosts already exist in centreon hosts list; if not, add host to centreon (needs work on values field; needs ganglia-host template, and docker-hosts host group)
      if [ ! $(list_include_item "$KNOWNHOSTS" "$host") ]; then
        curl -s -XPOST 'http://127.0.0.1/centreon/api/index.php?action=action&object=centreon_clapi' \
          --data "{
            \"action\": \"add\",
            \"object\": \"host\",
            \"values\": \"$host;$host;$host;ganglia-host;central;docker-hosts\"
          }" \
          -H "Content-Type:application/json" \
          -H "centreon_auth_token:$token"
        need_restart=1
      fi
    fi
 fi
done

# redemarage du pooler
if [ "$need_restart" == "1" ]; then
    curl -s -XPOST 'http://127.0.0.1/centreon/api/index.php?action=action&object=centreon_clapi' \
        --data '{"action": "APPLYCFG", "values": "1"}' \
        -H "Content-Type:application/json" \
        -H "centreon_auth_token:$token"
fi