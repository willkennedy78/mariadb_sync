# Power Automate Flow Setup Guide

This guide walks through creating the Power Automate flow that captures Microsoft Forms
responses and writes them as JSON files to SharePoint for the provisioning pipeline.

## Prerequisites

- Microsoft 365 account with Power Automate license
- Access to the SFTP Configuration Request form as owner/co-owner
- A SharePoint site where JSON files will be stored
- SharePoint document library with a folder structure:
  ```
  SFTP-Requests/
  └── pending/
  ```

## Step 1: Create the SharePoint Folder Structure

1. Navigate to your SharePoint site's document library
2. Create a folder called `SFTP-Requests`
3. Inside it, create a subfolder called `pending`
4. Note down:
   - **Site URL**: e.g., `https://yourorg.sharepoint.com/sites/OpsTeam`
   - **Library name**: e.g., `Documents` or `Shared Documents`

## Step 2: Create the Power Automate Flow

1. Go to [Power Automate](https://make.powerautomate.com)
2. Click **+ Create** > **Automated cloud flow**
3. Name it: `SFTP Request - Form to SharePoint`
4. Search for trigger: **"When a new response is submitted"** (Microsoft Forms connector)
5. Click **Create**

## Step 3: Configure the Trigger

1. In the trigger step, select:
   - **Form Id**: Choose your SFTP Configuration Request form from the dropdown
2. Click **+ New step**

## Step 4: Get Response Details

1. Search for: **"Get response details"** (Microsoft Forms connector)
2. Configure:
   - **Form Id**: Same form as the trigger
   - **Response Id**: Select `Response Id` from the dynamic content (from the trigger)

## Step 5: Compose the JSON Object

1. Click **+ New step**
2. Search for: **"Compose"** (Data Operations)
3. In the **Inputs** field, paste the following JSON template and map each field using
   dynamic content from the "Get response details" step:

```json
{
  "id": @{triggerOutputs()?['body/resourceData/responseId']},
  "submitted_at": @{body('Get_response_details')?['submitDate']},
  "responder_email": @{body('Get_response_details')?['responder']},
  "responder_name": @{body('Get_response_details')?['responderName']},
  "customer_name": @{body('Get_response_details')?['QUESTION_ID_FOR_CUSTOMER_NAME']},
  "requester_name": @{body('Get_response_details')?['QUESTION_ID_FOR_REQUESTER_NAME']},
  "environment": @{body('Get_response_details')?['QUESTION_ID_FOR_ENVIRONMENT']},
  "auth_method": @{body('Get_response_details')?['QUESTION_ID_FOR_AUTH_METHOD']},
  "password_restrictions": @{body('Get_response_details')?['QUESTION_ID_FOR_PASSWORD_RESTRICTIONS']},
  "password_requirements_detail": @{body('Get_response_details')?['QUESTION_ID_FOR_PASSWORD_DETAIL']},
  "public_key": @{body('Get_response_details')?['QUESTION_ID_FOR_PUBLIC_KEY']},
  "delivery_method": @{body('Get_response_details')?['QUESTION_ID_FOR_DELIVERY_METHOD']},
  "recipient_email": @{body('Get_response_details')?['QUESTION_ID_FOR_RECIPIENT_EMAIL']},
  "recipient_phone": @{body('Get_response_details')?['QUESTION_ID_FOR_RECIPIENT_PHONE']},
  "ip_whitelist": @{body('Get_response_details')?['QUESTION_ID_FOR_IP_WHITELIST']},
  "status": "pending"
}
```

**Important**: The `QUESTION_ID_FOR_*` placeholders will be automatically replaced with
the actual dynamic content when you click the field names from the "Get response details"
output in the Power Automate designer. Simply click each field in the JSON and select
the corresponding form question from the dynamic content panel.

## Step 6: Create the JSON File in SharePoint

1. Click **+ New step**
2. Search for: **"Create file"** (SharePoint connector)
3. Configure:
   - **Site Address**: Your SharePoint site URL
   - **Folder Path**: `/SFTP-Requests/pending`
   - **File Name**: Use an expression to generate a unique filename:
     ```
     concat('sftp-request-', formatDateTime(utcNow(), 'yyyyMMdd-HHmmss'), '-', triggerOutputs()?['body/resourceData/responseId'], '.json')
     ```
   - **File Content**: Select the **Output** from the Compose step

## Step 7: (Optional) Send Admin Notification

1. Click **+ New step**
2. Search for: **"Send an email (V2)"** (Office 365 Outlook connector)
3. Configure:
   - **To**: Your Ops team email or distribution group
   - **Subject**: `New SFTP Account Request: @{body('Get_response_details')?['CUSTOMER_NAME_FIELD']}`
   - **Body**: Summary of the request with a note to run the review script

## Step 8: Save and Test

1. Click **Save** in the top-right
2. Click **Test** > **Manually** > **Test**
3. Submit a test response to your form
4. Verify:
   - The flow ran successfully (check flow run history)
   - A JSON file appeared in `SFTP-Requests/pending/` on SharePoint
   - The JSON contains all form fields correctly

## Step 9: Note Your SharePoint IDs for Configuration

You'll need these values for `config/settings.json`:

### Finding the SharePoint Site ID
```powershell
# Using Microsoft Graph Explorer or PowerShell:
$siteUrl = "yourorg.sharepoint.com:/sites/OpsTeam"
Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$siteUrl" -Headers $headers
# Note the 'id' field
```

### Finding the Drive ID
```powershell
Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/{site-id}/drives" -Headers $headers
# Find the drive matching your document library and note its 'id'
```

## Troubleshooting

### "Get response details" fails for group forms
- Ensure the form is owned by a user, not a Microsoft 365 Group
- If the form is group-owned, the user running the flow must be a member of that group

### Flow doesn't trigger
- Verify the form ID is correct in the trigger
- Check that the form is published and accepting responses
- Ensure the flow is turned on (not paused)

### JSON file is empty or malformed
- Check the Compose step output in the flow run details
- Ensure all dynamic content references resolve correctly
- Test with the "Peek code" option on the Compose step to verify the expression

## Alternative: Direct Webhook Approach

If you prefer not to use SharePoint as the intermediate storage, you can replace
Step 6 with an HTTP POST action:

1. Instead of "Create file", use **"HTTP"** action
2. Configure:
   - **Method**: POST
   - **URI**: Your webhook endpoint URL
   - **Headers**: `Content-Type: application/json`
   - **Body**: Output from the Compose step

This requires running a lightweight webhook listener on your automation server.
See `docs/webhook-setup.md` for details (if implementing this approach).
