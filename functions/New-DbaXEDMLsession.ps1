Function New-DbaXEDMLsession
{
  <#
      .SYNOPSIS
      Creates a new Extended Events session to capture DML statements.

      .DESCRIPTION
      Creates an Extended Events session that collects insert, update and delete on one or more databases.

      .PARAMETER SqlInstance
      The SQL Server that you're connecting to

      .PARAMETER Credential
      Credential object used to connect to the SQL Server as a different user

      .PARAMETER Database
      Creates an Extended Events session only for these databases

      .PARAMETER Exclude
      Creates an Extended Events session for all but these specific databases

      .PARAMETER TargetDirectory
      The directory where the target files will be saved, as it is known on the SqlInstance.
      e.g. 'D:\MSSQL' will save .xel files on the D: drive of the computer where sqlInstance is.

      .NOTES
      Author: Klaas Vandenberghe ( @PowerDbaKlaas )

      dbatools PowerShell module (https://dbatools.io)
      Copyright (C) 2016 Chrissy LeMaire
      This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
      This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
      You should have received a copy of the GNU General Public License along with this program. If not, see http://www.gnu.org/licenses/.

      .LINK
      https://dbatools.io/New-DbaXEDMLsession

      .EXAMPLE
      New-DbaXEDMLsession -SqlInstance sqlserver2014a

      Creates an Extended Events session for all user databases of the sqlserver2014a instance

      .EXAMPLE
      New-DbaXEDMLsession -SqlInstance sqlserver2014a -Database HR, Accounting

      Creates an Extended Events session for both HR and Accounting database of the sqlserver2014a instance

      .EXAMPLE
      New-DbaXEDMLsession -SqlInstance sqlserver2014a -Exclude HR

      Creates an Extended Events session for all user databases of the sqlserver2014a instance except HR

      .EXAMPLE
      'sqlserver2014a' | New-DbaXEDMLsession

      Creates an Extended Events session for all user databases of sqlserver2014a instance

  #>
  [CmdletBinding()]
  Param (
    [parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [Alias("ServerInstance", "SqlServer")]
    [object]$SqlInstance,
    [parameter(Mandatory = $true, ValueFromPipeline = $false)]
    [object]$TargetDirectory,
    [PSCredential]
    [System.Management.Automation.CredentialAttribute()]$Credential
  )
  DynamicParam
  {
    if ($SqlInstance)
    {
      Get-ParamSqlDatabases -SqlServer $SqlInstance -SqlCredential $Credential -NoSystem
    }
  }
  BEGIN {
    $databases = $psboundparameters.Databases
    $exclude = $psboundparameters.Exclude
    $FunctionName = (Get-PSCallstack)[0].Command
  }
  PROCESS {
          Write-Verbose "$FunctionName - Connecting to $SqlInstance"
      try
      {
        $server = Connect-SqlServer -SqlServer $SqlInstance -SqlCredential $Credential
      }
      catch
      {
        Write-Warning "$FunctionName - Can't connect to $SqlInstance"
        Continue
      }
      $dbs = $server.Databases | Where-Object { $false -eq $_.IsSystemObject }

      if ($databases.count -gt 0)
      {
        $dbs = $dbs | Where-Object { $databases -contains $_.Name }
      }
      if ($exclude.count -gt 0)
      {
        $dbs = $dbs | Where-Object { $exclude -notcontains $_.Name }
      }
      foreach($db in $dbs)
      {
        $dbName = $db.name
        Write-Verbose "$FunctionName - Database Name is $dbName"
        $targetfile = $TargetDirectory + "\$dbName"+ '_DML_Target.xel'
        $XEsession = $dbName + '_DML'
        $DBIDquery = "select database_id from sys.databases where name = '$dbName';"
        $DBID = invoke-sqlcmd2 -ServerInstance $SqlInstance -Database $dbName -Query $DBIDquery -Credential $Credential
        $DBID = $DBID.database_id
        Write-Verbose "$FunctionName - Database ID is $DBID"

        $CreateXEDMLsql = @"

IF EXISTS (SELECT *
      FROM sys.server_event_sessions
      WHERE name = '$XEsession')
BEGIN
    DROP EVENT SESSION [$XEsession]
          ON SERVER;
END
;
CREATE EVENT SESSION [$XEsession]
    ON SERVER 
    ADD EVENT sqlserver.sql_statement_completed
    (
        ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.nt_username,sqlserver.sql_text)
        WHERE
        (( [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%INSERT %')
		OR
         [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%UPDATE %')
		OR
         [sqlserver].[like_i_sql_unicode_string]([sqlserver].[sql_text], N'%DELETE %'))
		AND
		[database_id]=($DBID))
    )
    ADD TARGET package0.event_file
    (SET
        filename = N'$targetfile',
        max_file_size = (2),
        max_rollover_files = (10)
    )
    WITH (
        MAX_MEMORY = 2048 KB,
        EVENT_RETENTION_MODE = ALLOW_MULTIPLE_EVENT_LOSS,
        MAX_DISPATCH_LATENCY = 3 SECONDS,
        MAX_EVENT_SIZE = 0 KB,
        MEMORY_PARTITION_MODE = NONE,
        TRACK_CAUSALITY = OFF,
        STARTUP_STATE = OFF
    );
"@

        invoke-sqlcmd2 -ServerInstance $SqlInstance -Database master -Query $CreateXEDMLsql -Credential $Credential
      } #foreach
  } #PROCESS
} #function