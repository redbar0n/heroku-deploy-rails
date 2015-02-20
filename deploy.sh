#!/bin/bash

BRANCH="${BRANCH:-master}"

# Run by typing (from the app root dir):   
#    heroku-deploy-rails/deploy.sh prod
# Add this line to your ~/.bash_profile, to be able to just type 'deploy prod' to run this script:
#    alias deploy='./heroku-deploy-rails/deploy.sh'


# Deploy script written as a shell script.
# It is better than alternative Ruby scripts because:
# - faster: it doesn't have to load the ruby environment
# - easier to read: less boilerplate code, so it is clearer to inspect the script to see what's going on

# Presumptions:
# - Using Git.
# - Local git remote for the production app is called "prod", if not then run in console:   git remote rename heroku prod
# - SSH keys are set up correctly.
# - No staging server. Because could use it like 'deploy staging' to deploy to a staging remote, if needed.
# - Does not commit to origin, because we want that to be a separate process.
# - Using PostgreSQL database with PG Backups Heroku addon. If not, then run this once:  heroku addons:add pgbackups:auto-month

# Potential future updates:
# - ensure_clean: Checking that there are no uncommitted files in your working copy. Basically a check you haven't forgotten anything and would need to deploy twice. Also ensures your uncommitted files won't be intertangled with merge conflicted files. Inspiration: https://gist.github.com/ahawkins/2237714
# - Testing your user can connect to heroku, and give error message if not. Inspiration: https://gist.github.com/ahawkins/2237714
# - Push all config/locales/<locale>.yml files to localeapp.com, to avoid hardcoding them here. Remember that <locale> files are only those with 2 characters, as the other .yml files should not be pushed.
# - Automatically log all pushes to prod, to some file. (Records this commit & time in a deploys file + Commits the deploy file + Pushes to Github + Pushes to Heroku)
# - Seed production, with any potential new seeds? Requires that the seed file can be run multiple times, without creating duplicates.    heroku run rake db:seed --app #{app_name}
# - Ensure using the same ruby as used locally for deployment
# - Start or restart delayed_jobs ?   delayed_job:start    delayed_job:restart
# - Start or restart cron jobs? (for regular time specific tasks)
# - Backup database? Inspiration from old deploy.sh script. Warning: Might increase deploy time considerably, if a large database. So it's been left out for now.

# [Script has been modified for Bloggery] - It was introduced to the app on February 19, 2015. It presumes Heroku deployment, and it's not using Capistrano.]

# Shell scripting documentation:
# -z STRING      True if string is empty.
# Parameters can be passed to functions, but functions are still named with () after them. Parameters can be accessed with $1 and $2 and so on.
# If statements automatically checks if the return code in their statement is successful or not

# Functions

usage()
{
    echo "Usage: [BRANCH=master] $(basename $0) <remote> [no-migrations]" >&2
    echo >&2
    echo "        remote         Name of git remote for Heroku app" >&2
    echo "        no-migrations  Deploy without running migrations" >&2
    echo >&2
    exit 1
}

has_remote()
{
    git remote | grep -qs "$REMOTE"
}

run_security_checks()
{
    # check if brakeman is installed, and redirect the output of the check (basically just a line with the install location) to null (meaning: discard it)
    if command -v brakeman >/dev/null; then
        brakeman
    fi
}

pull_from_origin()
{
    # Get changes from other devs, so amount of deploys needed is reduced.
    # This function must be run before show_undeployed_changes, to make sure that function will show all undeployed commits, including others' that you pulled in from origin.
    if ! git pull origin master; then
        # git pull failed
        echo "Resolve merge conflicts with origin, and commit them, before running the deploy script again. To ensure the latest version of origin matches prod."
        exit 0
    fi
    # git pull, when succeeding, will automatically echo "Current branch master is up to date", or that it has been fast forwarded.
}

show_undeployed_changes()
{
    git fetch $REMOTE
    local range="$REMOTE/master..$BRANCH"
    local commits=$(git log --reverse --pretty=format:'%h | %cr: %s (%an)' $range)
    
    if [ -z "$commits" ]; then
        # -z STRING      True if string is empty.
        # commits variable is empty
        echo "Nothing to deploy"
        exit 1
    else
        echo -e "Undeployed commits:\n"
        echo -e "$commits"
        echo -e -n "\nPress enter to continue... "
        read
    fi
}

push_to_origin()
{
    # To ensure the latest version of origin matches prod. So no one ever has to pull from prod because it is ahead of origin.
    git push origin master
}

# params:
#   $1: <locale>
push_if_locale_file_has_changed()
{
    # relies on $REMOTE having been fetched in show_undeployed_changes, which will update local copies of master branch on production
    local changes=$(git diff "$REMOTE/master" -- "config/locales/$1.yml") # $1 refers to the first input parameter to this function
    if [ -z "$changes" ]; then
        # changes variable is empty -> no changes
        echo "No new translations in $1.yml, which doesn't already exist on prod. -> Skipping push to localeapp.com."
    else
        echo "New translations in $1.yml, compared to prod. -> Pushing it to localeapp.com."
        # localeapp needs to start a Ruby instance, unfortunately, which takes a few extra seconds
        localeapp push config/locales/$1.yml
    fi
}

push_translations_to_localeapp()
{
    push_if_locale_file_has_changed "en"
    push_if_locale_file_has_changed "nb"
    # add lines here for additional locale files
}

deploy_changes()
{
    if [ "$REMOTE" = "prod" ]; then
        git push $REMOTE $BRANCH:master
    else
        git push -f $REMOTE $BRANCH:master
    fi
}

running_migrations()
{
    [ "$COMMAND" != "no-migrations" ]
}

migrate_database()
{
    if running_migrations; then
        heroku maintenance:on --remote $REMOTE
        heroku run rake db:migrate --remote $REMOTE
        heroku maintenance:off --remote $REMOTE
    fi
}

restart_heroku()
{
    # Will only restart app with appname identical to current folder directory.
    heroku restart
}


# Main program

set -e

REMOTE="$1"
COMMAND="$2"

[ -n "$DEBUG" ] && set -x
[ -z "$REMOTE" ] && usage

[ ! has_remote ] && usage

run_security_checks
pull_from_origin
show_undeployed_changes
push_to_origin
push_translations_to_localeapp
deploy_changes
migrate_database
restart_heroku
