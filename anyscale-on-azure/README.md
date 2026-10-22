# Anyscale on Azure

This guide covers configuring the Anyscale Kubernetes Operator authentication service principal in Microsoft Entra ID.

[View the slides](web-slides.html).

> 📊 **Need an overview of AnyScale on Azure?** 
>
> Open [Introduction](https://oxcp.github.io/ainotes/anyscale-on-azure/web-slides.html) to quickly overview the AnyScale on Azure.

## Create the Operator Authentication Service Principal

Create a service principal in the current Microsoft Entra tenant for the **Anyscale Kubernetes Operator Auth** application:

```bash
az ad sp create --id 086bc555-6989-4362-ba30-fded273e432b
```

### Example Output

The following is a sample response with identifiers masked using placeholders. The command above retains the application ID needed to create the service principal.

```json
{
  "@odata.context": "https://graph.microsoft.com/v1.0/$metadata#servicePrincipals/$entity",
  "accountEnabled": true,
  "addIns": [],
  "alternativeNames": [],
  "appDescription": null,
  "appDisplayName": "Anyscale Kubernetes Operator Auth",
  "appId": "<APPLICATION-ID>",
  "appOwnerOrganizationId": "<APP-OWNER-TENANT-ID>",
  "appRoleAssignmentRequired": false,
  "appRoles": [],
  "applicationTemplateId": null,
  "createdByAppId": "<CREATOR-APPLICATION-ID>",
  "createdDateTime": null,
  "deletedDateTime": null,
  "description": null,
  "disabledByMicrosoftStatus": null,
  "displayName": "Anyscale Kubernetes Operator Auth",
  "homepage": null,
  "id": "<SERVICE-PRINCIPAL-OBJECT-ID>",
  "info": {
    "logoUrl": null,
    "marketingUrl": null,
    "privacyStatementUrl": null,
    "supportUrl": null,
    "termsOfServiceUrl": null
  },
  "isDisabled": null,
  "keyCredentials": [],
  "loginUrl": null,
  "logoutUrl": null,
  "notes": null,
  "notificationEmailAddresses": [],
  "oauth2PermissionScopes": [],
  "passwordCredentials": [],
  "preferredSingleSignOnMode": null,
  "preferredTokenSigningKeyThumbprint": null,
  "replyUrls": [],
  "resourceSpecificApplicationPermissions": [],
  "samlSingleSignOnSettings": null,
  "servicePrincipalNames": [
    "<APPLICATION-ID>",
    "api://<APPLICATION-ID>"
  ],
  "servicePrincipalType": "Application",
  "signInAudience": "AzureADMultipleOrgs",
  "tags": [],
  "tokenEncryptionKeyId": null,
  "verifiedPublisher": {
    "addedDateTime": null,
    "displayName": null,
    "verifiedPublisherId": null
  }
}
```