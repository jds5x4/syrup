require 'date'

module Syrup
  module Institutions
    class ZionsBank < InstitutionBase
      
      class << self
        def name
          "Zions Bank"
        end
        
        def id
          "zions_bank"
        end
      end
      
      def fetch_account(account_id)
        fetch_accounts
      end
      
      def fetch_accounts
        ensure_authenticated

        # List accounts
        page = agent.get('https://banking.zionsbank.com/ibuir/displayAccountBalance.htm')
        json = MultiJson.load(page.body)

        accounts = []
        json['accountBalance']['depositAccountList'].each do |account|
          new_account = Account.new(:id => account['accountId'], :institution => self)
          new_account.name = unescape_html(account['name'])
          new_account.account_number = account['number']
          new_account.current_balance = parse_currency(account['currentAmt'])
          new_account.available_balance = parse_currency(account['availableAmt'])
          new_account.type = :deposit
          
          accounts << new_account
        end
        json['accountBalance']['creditAccountList'].each do |account|
          new_account = Account.new(:id => account['accountId'], :institution => self)
          new_account.name = unescape_html(account['name'])
          new_account.account_number = account['number']
          new_account.current_balance = parse_currency(account['balanceDueAmt'])
          new_account.type = :credit
          
          accounts << new_account
        end

        accounts
      end
      
      def fetch_transactions(account_id, starting_at, ending_at)
        ensure_authenticated
        
        transactions = []
        
        post_vars = { "actAcct" => account_id, "dayRange.searchType" => "dates", "dayRange.startDate" => starting_at.strftime('%m/%d/%Y'), "dayRange.endDate" => ending_at.strftime('%m/%d/%Y'), "submit_view.x" => 11, "submit_view.y" => 11, "submit_view" => "view" }
        
        page = agent.post("https://banking.zionsbank.com/zfnb/userServlet/app/bank/user/register_view_main?reSort=false&actAcct=#{account_id}", post_vars)
        
        # Get all the transactions
        page.search('tr').each do |row_element|
          # Look for the account information first
          account = find_account_by_id(account_id)
          datapart = row_element.css('.acct')
          if datapart && datapart.inner_html.size > 0
            if match = /Prior Day Balance:\s*([^<]+)/.match(datapart.inner_html)
              account.prior_day_balance = parse_currency(match[1])
            end
            if match = /Current Balance:\s*([^<]+)/.match(datapart.inner_html)
              account.current_balance = parse_currency(match[1])
            end
            if match = /Available Balance:\s*([^<]+)/.match(datapart.inner_html)
              account.available_balance = parse_currency(match[1])
            end
          end
        
          data = []
          datapart = row_element.css('.data')
          if datapart
            data += datapart
            datapart = row_element.css('.curr')
            data += datapart if datapart
          end
          
          datapart = row_element.css('.datagrey')
          if datapart
            data += datapart
            datapart = row_element.css('.currgrey')
            data += datapart if datapart
          end
          
          if data.size == 7
            data.map! {|cell| cell.inner_html.strip.gsub(/[^ -~]/, '') }
            
            transaction = Transaction.new

            transaction.posted_at = Date.strptime(data[0], '%m/%d/%Y')
            transaction.payee = unescape_html(data[2])
            transaction.status = data[3].include?("Posted") ? :posted : :pending
            unless data[4].empty?
              transaction.amount = -parse_currency(data[4])
            end
            unless data[5].empty?
              transaction.amount = parse_currency(data[5])
            end
            
            transactions << transaction
          end
        end
        
        transactions
      end
      
      private
      
      def ensure_authenticated
        
        # Check to see if already authenticated
        page = agent.get('https://banking.zionsbank.com/ibuir/')
        if page.body.include?("SessionTimeOutException")
          
          raise InformationMissingError, "Please supply a username" unless self.username
          raise InformationMissingError, "Please supply a password" unless self.password
          
          # Enter the username
          page = agent.get('https://www.zionsbank.com')
          form = page.form('logonForm')
          form.pm_fp = "version%3D1%26pm%5Ffpua%3Dmozilla%2F5%2E0%20%28windows%20nt%206%2E1%3B%20wow64%29%20applewebkit%2F535%2E19%20%28khtml%2C%20like%20gecko%29%20chrome%2F18%2E0%2E1025%2E162%20safari%2F535%2E19%7C5%2E0%20%28Windows%20NT%206%2E1%3B%20WOW64%29%20AppleWebKit%2F535%2E19%20%28KHTML%2C%20like%20Gecko%29%20Chrome%2F18%2E0%2E1025%2E162%20Safari%2F535%2E19%7CWin32%26pm%5Ffpsc%3D32%7C1920%7C1200%7C1200%26pm%5Ffpsw%3D%7Cqt1%7Cqt2%7Cqt3%7Cqt4%7Cqt5%7Cqt6%26pm%5Ffptz%3D%2D6%26pm%5Ffpln%3Dlang%3Den%2DUS%7Csyslang%3D%7Cuserlang%3D%26pm%5Ffpjv%3D1%26pm%5Ffpco%3D1"
          form.publicCred1 = username
          page = form.submit

          # If the supplied username is incorrect, raise an exception
          raise InformationMissingError, "Invalid username" if page.title == "Error Page"

          # Go on to the next page
          page = page.links.first.click

          refresh = page.body.match /meta http-equiv="Refresh" content="0; url=([^"]+)/
          if refresh
            url = refresh[1]
            page = agent.get("https://securentry.zionsbank.com#{url}")
          end
          
          # Skip the secret question if we are prompted for the password
          unless page.body.include?("Site Validation and Password")
            # Find the secret question
            question = page.search('div.form_field')[2].css('div').inner_text
            
            # If the answer to this question was not supplied, raise an exception
            raise InformationMissingError, "Please answer the question, \"#{question}\"" unless secret_questions && secret_questions[question]
            
            # Enter the answer to the secret question
            form = page.forms.first
            form["challengeEntry.answerText"] = secret_questions[question]
            form.radiobutton_with(:value => 'false').check
            submit_button = form.button_with(:name => '_eventId_submit')
            page = form.submit(submit_button)
            
            # If the supplied answer is incorrect, raise an exception
            raise InformationMissingError, "\"#{secret_questions[question]}\" is not the correct answer to, \"#{question}\"" unless page.search('#errorComponent').empty?
          end

          # Enter the password
          form = page.forms.first
          form.privateCred1 = password
          submit_button = form.button_with(:name => '_eventId_submit')
          page = form.submit(submit_button)
          
          # If the supplied password is incorrect, raise an exception
          raise InformationMissingError, "An invalid password was supplied" unless page.search('#errorComponent').empty?

          # Clicking this link logs us into the banking.zionsbank.com domain
          page = page.links.first.click
          
          if page.uri.to_s != "https://banking.zionsbank.com/ibuir/displayUserInterface.htm"
            page = agent.get('https://banking.zionsbank.com/zfnb/userServlet/app/bank/user/viewaccountsbysubtype/viewAccount')
            
            raise "Unknown URL reached. Try logging in manually through a browser." if page.body.include?("SessionTimeOutException")
          end
        end
        
        true
      end
      
    end
  end
end
