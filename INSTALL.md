# Installation & Setup Guide

## Step 1: Install the Package

Install the latest version (v0.5.0) using one of these methods:

**CLI:**
```bash
sf package install --package PACKAGE_VERSION_ID --wait 10 --installation-key-bypass
```

**Browser:**
- [Install in Production / Developer Org](https://login.salesforce.com/packaging/installPackage.apexp?p0=PACKAGE_VERSION_ID)
- [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=PACKAGE_VERSION_ID)

Select **Install for Admins Only** during installation.

## Step 2: Assign Permission Sets

| Permission Set | For | What It Grants |
|---------------|-----|----------------|
| **DocGen Admin** | Admins, template managers | Full access: template CRUD, bulk generation, sharing, setup wizard |
| **DocGen User** | End users | Generate documents from existing templates |
| **DocGen Guest Signature** | Site guest users (auto-assigned) | Signature submission via public VF pages |

Go to **Setup > Permission Sets**, open the set, and click **Manage Assignments**.

## Step 3: Add Generator to Record Pages

1. Navigate to any record page (Account, Opportunity, etc.)
2. Click the gear icon > **Edit Page**
3. Drag the **docGenRunner** component onto the layout
4. Save and activate

## Step 4: Configure PDF Engine (Optional)

Required only if you need PDF output. Navigate to the **DocGen Setup** tab and follow the 4-step wizard:

1. **Connected App** -- Create "DocGen Loopback" with OAuth scopes `api` and `refresh_token`
2. **Auth Provider** -- Create using the Consumer Key/Secret from Step 1
3. **Named Credential** -- Create `DocGen_Loopback` external credential, then authenticate
4. **Site URL** -- Enter your Salesforce Site base URL (for signature links)

## Step 5: Configure E-Signatures (Optional)

1. **Create a Salesforce Site** -- Setup > Sites > New. Set the default page to `DocGenSignature`
2. **Guest User Access** -- Enable `DocGenSignature`, `DocGenSign`, and `DocGenVerify` VF pages on the guest user profile
3. **Guest Permission Set** -- Assign `DocGen Guest Signature` to the site's guest user
4. **Save Site URL** -- Enter the site base URL in DocGen Setup (Step 4 of the wizard)

No Experience Cloud site or Flow configuration required.
