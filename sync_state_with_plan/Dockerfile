FROM git.softline.com/registry/python-image:v3
COPY sync_state_with_plan.py /sync_state_with_plan.py
ENTRYPOINT ["sh", "-c", "python /sync_state_with_plan.py && echo \"::set-output name=log::$(cat changes_log.json)\""]