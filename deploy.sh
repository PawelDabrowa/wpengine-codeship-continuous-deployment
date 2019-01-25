#!/bin/bash
# If any commands fail (exit code other than 0) entire script exits
set -e

# Check for required environment variables and make sure they are setup
: ${WPE_PROD_INSTALL?"WPE_PROD_INSTALL Missing"}   # subdomain for wpengine production install
: ${WPE_DEV_INSTALL?"WPE_DEV_INSTALL Missing"}   # subdomain for wpengine development install
: ${REPO_NAME?"REPO_NAME Missing"}       # theme repo name (Typically the folder name of the project)
: ${PROJECT_TYPE?"PROJECT_TYPE Missing"} # Whether to push theme or plugins

# Set repo based on current branch, by default master=production, develop=staging
# @todo support custom branches

if [ "$CI_BRANCH" == "master" ]
then
    target_wpe_install=${WPE_PROD_INSTALL}
else
    target_wpe_install=${WPE_DEV_INSTALL}
fi

if [[ "$CI_BRANCH" == "qa" && -n "$WPE_QA_INSTALL" ]]
then
    target_wpe_install=${WPE_QA_INSTALL}
    repo=production
fi

# Set Global PHP version

phpenv global 7.2

# Begin from the ~/clone directory
# this directory is the default your git project is checked out into by Codeship.
cd ~/clone

# Get official list of files/folders that are not meant to be on production if $EXCLUDE_LIST is not set.
if [[ -z "${EXCLUDE_LIST}" ]];
then
    wget https://raw.githubusercontent.com/humet/wpengine-codeship-continuous-deployment/master/exclude-list.txt
else
    # @todo validate proper url?
    wget ${EXCLUDE_LIST}
fi

# Loop over list of files/folders and remove them from deployment
ITEMS=`cat exclude-list.txt`
for ITEM in $ITEMS; do
    if [[ $ITEM == *.* ]]
    then
        find . -depth -name "$ITEM" -type f -exec rm "{}" \;
    else
        find . -depth -name "$ITEM" -type d -exec rm -rf "{}" \;
    fi
done

# Remove exclude-list file
rm exclude-list.txt

# Clone the WPEngine files to the deployment directory
# if we are not force pushing our changes
if [[ $CI_MESSAGE != *#force* ]]
then
    force=''
    git clone git@git.wpengine.com:production/${target_wpe_install}.git ~/deployment
else
    force='-f'
    if [ ! -d "~/deployment" ]; then
        mkdir ~/deployment
        cd ~/deployment
        git init
    fi
fi

if [[ $CI_MESSAGE = *#nolint* ]]
then
  force='-o nolint'
fi

# If there was a problem cloning, exit
if [ "$?" != "0" ] ; then
    echo "Unable to clone ${repo}"
    kill -SIGINT $$
fi

# Move the gitignore file to the deployments folder
cd ~/deployment
wget --output-document=.gitignore https://raw.githubusercontent.com/humet/wpengine-codeship-continuous-deployment/master/gitignore-template.txt

# Delete plugins and theme if it exists, and move cleaned version into deployment folder
if [ "$PROJECT_TYPE" == "theme" ]
  then
  rm -rf /wp-content/themes/${REPO_NAME}
elif [ "$PROJECT_TYPE" == "plugin" ]
  then
  rm -rf /wp-content/plugins
fi

# Check to see if the wp-content directory exists, if not create it
if [ ! -d "./wp-content" ]; then
    mkdir ./wp-content
fi
# Check to see if the plugins directory exists, if not create it
if [ ! -d "./wp-content/plugins" ]; then
    mkdir ./wp-content/plugins
else
  if [ "$PROJECT_TYPE" == "plugin" ]
  then
    rm -r ./wp-content/plugins
    mkdir ./wp-content/plugins
  fi
fi
# Check to see if the themes directory exists, if not create it
if [ ! -d "./wp-content/themes" ]; then
    mkdir ./wp-content/themes
fi

# Install plugin/theme packages
cd ../clone && composer install

if [ "$PROJECT_TYPE" == "theme" ]
then
  # Install theme packages and compile into production version
  yarn cache clean && yarn && yarn run build:production
fi

cd ~/deployment

if [ "$PROJECT_TYPE" == "theme" ]
then
  rsync -a ../clone/* ./wp-content/themes/${REPO_NAME}
fi

if [ "$PROJECT_TYPE" == "plugin" ]
then
  rsync -a ../clone/* ./
fi

# Stage, commit, and push to wpengine repo

echo "Add remote"

git remote add production git@git.wpengine.com:production/${target_wpe_install}.git

git config --global user.email CI_COMMITTER_EMAIL
git config --global user.name CI_COMMITTER_NAME
git config core.ignorecase false
git add --all
git commit -am "Deployment to ${target_wpe_install} production by $CI_COMMITTER_NAME from $CI_NAME"

git push ${force} production master
