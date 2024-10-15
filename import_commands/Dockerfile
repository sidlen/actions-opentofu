FROM git.softline.com/registry/python-image:v3
COPY list_commands.py /list_commands.py
VOLUME /workspace
WORKDIR /workspace
ENTRYPOINT ["sh", "-c", "python /list_commands.py && echo \"::set-output name=list_commands::$(cat import_commands.sh)\""]