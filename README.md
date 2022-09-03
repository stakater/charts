# charts

Stakater Helm Charts

## Release new Chart

1. Test the chart locally to make sure that it works. Pipeline only checks the linting errors
2. Create a pull request containing the change
3. Only change one chart at a time, changing more than one chart will fail the pipeline
4. Bump the chart version manually, not changing the chart version will fail the pipeline
5. When merging the PR into main, use the option **Rebase and Merge**. **DO NOT** use the option **Merge**, otherwise the push pipeline will fail and will not publish the charts

## Local Testing

To test the chart locally, go to the chart folder `cd stakater/<chart-name>` use following commands

Download dependencies:

```yaml
helm dependency update
```

Install chart:

```yaml
helm install <release-name> . -n <namespace>
```

Uninstall chart:

```yaml
helm delete <release-name> -n <namespace>
```
