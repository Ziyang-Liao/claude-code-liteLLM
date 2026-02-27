FROM ghcr.io/berriai/litellm:main-latest
COPY patches/anthropic_claude3_transformation.py /usr/lib/python3.13/site-packages/litellm/llms/bedrock/messages/invoke_transformations/anthropic_claude3_transformation.py
