# charts

Stakater Helm Charts

## Release new Chart

1. Create a pull request containing the change
2. Only change one chart at a time, changing more than one chart will fail the pipeline
3. Bump the chart version manually, not changing the chart version will fail the pipeline
4. Manually do rebase and merge instead of just merging the PR, otherwise the push pipeline will fail and will not publish the charts
