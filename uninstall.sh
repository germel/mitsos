#!/bin/bash

# This erases everyting
for ext in cluster dns kms; do \
  gcloud projects delete "$base-$ext"; \
done
