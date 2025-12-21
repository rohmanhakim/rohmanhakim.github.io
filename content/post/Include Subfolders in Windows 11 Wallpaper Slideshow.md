---
title: "Include Subfolders in Windows 11 Wallpaper Slideshow"
date: 2025-08-24
draft: false
tags:
    - windows-11
    - wallpaper
    - slideshow
    - powershell
    - tutorial
categories: 
    - tech
summary: "Learn how to include images from subfolders in your Windows 11 wallpaper slideshow by using a PowerShell script to create symbolic links."
---

Windows 11 has a feature that enables us to change desktop wallpapers at specified intervals. However, by default, it only scans pictures in the root directory of our choice and doesn't allow us to include its subfolders. To change this, we need to make changes to the Windows 11 system.

# Install link_Nto1 PowerShell Script

link_Nto1 is a PowerShell script that helps us create hard/symbolic links to all files of a specified source folder inside a specified destination folder. In the context of this post, we can specify our wallpapers folder (which contains subfolders), and then the script will make symbolic links to all pictures in its subfolders. The script then places those symbolic links in certain folders which we specify, then we can make Windows 11 use that folder instead of our original wallpapers folder.

Begin installing the script by running PowerShell as Administrator:

```powershell
PS> Install-Script -Name link_Nto1
```

Then `cd` to our wallpapers folder:

```powershell
PS> cd C:/Users/myuser/wallpapers
```

Create a new folder that will store the generated symbolic links:

```powershell
PS> mkdir desktop_slideshow
```

Suppose in the `wallpapers` folder we have these subfolders: `animals`, `floral`, `landscapes`, then execute the script by passing these arguments:

```powershell
PS> link_Nto1.ps1 desktop_slideshow animals,floral,landscapes
```

⚠️ If you get this error:

```powershell
link_Nto1.ps1 : File C:\Program Files\WindowsPowerShell\Scripts\link_Nto1.ps1 cannot be loaded because running scripts is disabled on this system. For more information, see about_Execution_Policies at https:/go.microsoft.com/fwlink/?LinkID=135170. 
```

We need to change our Execution Policy **before** we run the link_Nto1 script. Run this in PowerShell:

```powershell
PS> Set-ExecutionPolicy RemoteSigned
```

After we run the link_Nto1 script, change the Execution Policy back:

```powershell
PS> Set-ExecutionPolicy Restricted
```

# Set the Windows 11 slideshow source to the desktop_slideshow folder

1. Go to Settings > Personalization > Background
    
2. In the "Choose a picture album for a slideshow", pick the `desktop_slideshow` folder we've just created from prior steps.
    

Windows 11 will now include all pictures inside our wallpapers folder. Cheers!